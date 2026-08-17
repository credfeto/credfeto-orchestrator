#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

# Covers notify-unit-failure, the OnFailure= handler installed by install-timer (#1361).
#
# This script IS the last-resort alerting path: it runs as a separate unit precisely so it still
# works when oneshot is too broken to report on itself. Every silent-failure mode here re-creates
# the 19.5-hour outage it exists to make audible, so the tests below focus on "does it stay loud"
# and "does it avoid leaking secrets" rather than on happy-path formatting.

load test_helper

SCRIPT="${REPO_ROOT}/notify-unit-failure"

setup() {
    setup_isolated_env
    CONFIG_DIR="${TEST_TMP}/config/orchestrator"
    mkdir -p "${CONFIG_DIR}"
    export XDG_CONFIG_HOME="${TEST_TMP}/config"
    CURL_LOG="${TEST_TMP}/curl.log"
    # curl stub records the payload it was handed instead of making a real request.
    cat > "${STUB_BIN}/curl" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${CURL_LOG}"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/curl"
    # journalctl stub: overridden per-test where the content matters.
    make_stub journalctl 'printf "ordinary log line\n"'
}

teardown() {
    cleanup_stubs
}

@test "notify-unit-failure posts an alert when the webhook is configured" {
    printf 'DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc\n' > "${CONFIG_DIR}/.env"

    run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    [ -f "${CURL_LOG}" ]
    grep -q "my-unit.service" "${CURL_LOG}"
}

@test "notify-unit-failure complains on stderr rather than exiting silently when unconfigured" {
    # No .env at all. lib/discord can afford to be silent because oneshot has other signals;
    # this script has none, so silence here is indistinguishable from a working alerting path.
    run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not found"* ]]
    [ ! -f "${CURL_LOG}" ]
}

@test "notify-unit-failure complains on stderr when DISCORD_WEBHOOK is absent from the config" {
    printf 'SOMETHING_ELSE=1\n' > "${CONFIG_DIR}/.env"

    run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DISCORD_WEBHOOK not set"* ]]
    [ ! -f "${CURL_LOG}" ]
}

@test "notify-unit-failure refuses a non-https webhook value" {
    # curl takes the URL positionally, so a value starting with '-' would be read as an option
    # (-o writes a file, -K reads a config).
    printf 'DISCORD_WEBHOOK=-o/tmp/pwned\n' > "${CONFIG_DIR}/.env"

    run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not an https URL"* ]]
    [ ! -f "${CURL_LOG}" ]
}

@test "notify-unit-failure fails loudly when given no unit name" {
    run "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no unit name given"* ]]
}

@test "notify-unit-failure redacts token-shaped strings from journal output (#1361)" {
    printf 'DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc\n' > "${CONFIG_DIR}/.env"
    # oneshot logs denied tool calls verbatim, including their full command text, so a blocked
    # `curl -H "Authorization: Bearer ..."` genuinely can reach the journal.
    make_stub journalctl 'printf "denied: curl -H \"Authorization: Bearer ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"\n"'

    run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "${CURL_LOG}")" -eq 0 ]
    grep -q "REDACTED" "${CURL_LOG}"
}

@test "notify-unit-failure redacts an anthropic key from journal output (#1361)" {
    printf 'DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc\n' > "${CONFIG_DIR}/.env"
    make_stub journalctl 'printf "token was sk-ant-api03-SECRETSECRETSECRET\n"'

    run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'SECRETSECRETSECRET' "${CURL_LOG}")" -eq 0 ]
    grep -q "REDACTED-ANTHROPIC-KEY" "${CURL_LOG}"
}

@test "notify-unit-failure truncates oversized journal context (#1361)" {
    printf 'DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc\n' > "${CONFIG_DIR}/.env"
    # Discord rejects an over-long embed description with a 400, losing the alert entirely.
    # shellcheck disable=SC2016  # stub body must reach the stub file unexpanded
    make_stub journalctl 'for i in $(seq 1 400); do printf "some quite long journal line of filler text %s\n" "$i"; done'

    run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    grep -q "truncated" "${CURL_LOG}"
}

@test "notify-unit-failure still alerts when jq is unavailable (#1361)" {
    printf 'DISCORD_WEBHOOK=https://discord.com/api/webhooks/1/abc\n' > "${CONFIG_DIR}/.env"
    # Under set -e a missing jq would otherwise abort before curl ever ran, and the notifier unit
    # deliberately has no OnFailure= of its own — so that failure would be completely silent.
    # `command -v jq` must find nothing, so build a PATH containing every tool the script needs
    # EXCEPT jq. Simply emptying PATH would remove grep/sed/cut too and prove nothing.
    local nojq="${TEST_TMP}/nojq"
    mkdir -p "${nojq}"
    local tool
    # bash included because the curl/journalctl stubs use a `#!/usr/bin/env bash` shebang, which
    # resolves bash via PATH.
    for tool in grep sed cut tail tr bash env; do
        ln -sf "$(command -v "${tool}")" "${nojq}/${tool}"
    done
    ln -sf "${STUB_BIN}/curl" "${nojq}/curl"
    ln -sf "${STUB_BIN}/journalctl" "${nojq}/journalctl"

    PATH="${nojq}" run "${SCRIPT}" my-unit.service
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"jq unavailable"* ]]
    # The alert must still go out — losing the journal context is acceptable, losing the alert is not.
    grep -q "my-unit.service" "${CURL_LOG}"
}
