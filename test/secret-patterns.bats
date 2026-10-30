#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

# Covers lib/secret-patterns and the copies of it that cannot source it. notify-unit-failure runs
# when the orchestrator itself is broken and cfwf is installed on its own, so both carry their own
# version of the secret forms. These tests are what stops the copies drifting apart: a form added
# to one list and not the others would leave one outbound channel still leaking it.

bats_require_minimum_version 1.5.0

load test_helper

NOTIFY_SCRIPT="${REPO_ROOT}/notify-unit-failure"
CFWF_SCRIPT="${REPO_ROOT}/containers/base/development-full/scripts/cfwf"

# One sample of every form the shared list redacts. Each is long enough to pass every copy's
# minimum length, so a test failure means a missing form rather than a too-short sample.
SECRET_SAMPLES=(
    'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    'github_pat_ABCDEFGHIJ0123456789xyz'
    'sk-ant-ABCDEFGHIJKLMNOPQRST'
    'sk-proj-ABCDEFGHIJKLMNOPQRST'
    'xoxb-1234567890-abcdefghij'
    'https://discord.com/api/webhooks/123456/abcDEF_-x'
    'https://discordapp.com/api/webhooks/123456/abcDEF_-x'
    'AKIAIOSFODNN7EXAMPLE' # gitleaks:allow
    'Bearer abcdefghij0123456789klmn'
)

setup() {
    setup_isolated_env
    # cfwf body check must refuse a leaking body before it ever reaches gh, so any gh call fails.
    make_stub gh 'printf "gh must not be called\n" >&2; exit 99'
    # shellcheck source=../lib/secret-patterns disable=SC1091
    source "${REPO_ROOT}/lib/secret-patterns"
}

@test "secret-patterns: notify-unit-failure carries the shared expressions verbatim and in order" {
    local inline
    inline=$(sed -n -E "s/^    -e '(.*)'( \\\\|\))$/\1/p" "${NOTIFY_SCRIPT}")
    local shared
    shared=$(printf '%s\n' "${SECRET_REDACTION_SED_EXPRESSIONS[@]}")

    [ -n "${inline}" ]
    [ "${inline}" = "${shared}" ]
}

@test "secret-patterns: redact_secrets removes every sample and keeps the surrounding text" {
    local sample
    local output_text
    for sample in "${SECRET_SAMPLES[@]}"; do
        output_text=$(printf 'before %s after' "${sample}" | redact_secrets)
        if [[ "${output_text}" == *"${sample}"* ]]; then
            printf 'not redacted: %s\n' "${sample}" >&2
            return 1
        fi
        [[ "${output_text}" == "before "*"[REDACTED"*"] after" ]]
    done
}

@test "secret-patterns: cfwf body check refuses every sample the shared list redacts" {
    local sample
    for sample in "${SECRET_SAMPLES[@]}"; do
        printf 'before %s after\n' "${sample}" > "${TEST_TMP}/leak.md"
        run --separate-stderr "${CFWF_SCRIPT}" body check --repo credfeto/credfeto-orchestrator --body-file "${TEST_TMP}/leak.md"
        if [ "${status}" -ne 8 ]; then
            printf 'cfwf accepted (status %s): %s\n' "${status}" "${sample}" >&2
            return 1
        fi
    done
}

@test "secret-patterns: every sample is a form the shared list redacts" {
    [ "${#SECRET_SAMPLES[@]}" -ge "${#SECRET_REDACTION_SED_EXPRESSIONS[@]}" ]
    local expression
    local sample
    local matched
    for expression in "${SECRET_REDACTION_SED_EXPRESSIONS[@]}"; do
        matched=false
        for sample in "${SECRET_SAMPLES[@]}"; do
            if [ "$(printf '%s' "${sample}" | sed -E -e "${expression}")" != "${sample}" ]; then
                matched=true
                break
            fi
        done
        if [ "${matched}" != true ]; then
            printf 'no sample exercises: %s\n' "${expression}" >&2
            return 1
        fi
    done
}
