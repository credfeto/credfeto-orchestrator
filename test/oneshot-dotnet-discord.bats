#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_DISCORD (#252): off by default; when on, the lib/discord payload builders ask
# ORCHESTRATOR_CMD discord payload <kind> for the payload, print it when the tool gives one (exit 0) and build it in
# bash, with a warning, when it does not. Posting the payload stays in bash, and the webhook URL never reaches the
# tool. test/oneshot-discord-parity.bats checks what both sides print.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

DISCORD_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/discord-parity.json"

# A stand-in for the tool: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---), writes "tool stderr"
# to stderr, prints ${TEST_TMP}/answer and exits with ${TEST_TMP}/status (0 when absent)
_make_discord_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'printf "tool stderr\n" >&2' \
        'if [ -f "${TEST_TMP}/answer" ]; then cat "${TEST_TMP}/answer"; fi' \
        'if [ -f "${TEST_TMP}/status" ]; then exit "$(cat "${TEST_TMP}/status")"; fi' \
        'exit 0'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

_tool_answers() {
    printf '%s' "$1" > "${TEST_TMP}/answer"
    printf '%s' "$2" > "${TEST_TMP}/status"
}

# The builders, from the fixture (test/oneshot-discord-parity.bats checks it lists every one in lib/discord)
_discord_builders() {
    jq -r '.functions | keys[]' "${DISCORD_FIXTURE}"
}

# Runs builder $1 with one argument per option, the Nth being N, a valid number and text alike
_call_builder() {
    local count arg args=()
    count=$(jq -r --arg f "$1" '.functions[$f].options | length' "${DISCORD_FIXTURE}")
    for ((arg = 1; arg <= count; arg++)); do
        args+=("${arg}")
    done
    "$1" "${args[@]}"
}

@test "ORCHESTRATOR_DOTNET_DISCORD defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_DISCORD bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_DISCORD}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "the lib/discord payload builders never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_DISCORD is off (#252)" {
    local function
    _make_discord_cmd_stub
    ORCHESTRATOR_DOTNET_DISCORD=0
    for function in $(_discord_builders); do
        run --separate-stderr _call_builder "${function}"
        [ "${status}" -eq 0 ]
        [ "$(printf '%s' "${output}" | jq -r '.embeds | length')" = 1 ]
        [ -z "${stderr}" ]
    done
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "each lib/discord payload builder hands its kind and options to ORCHESTRATOR_CMD and prints its answer as it is (#252)" {
    local function expected count arg
    _make_discord_cmd_stub
    _tool_answers $'{"tool": "payload"}\n\n' 0
    ORCHESTRATOR_DOTNET_DISCORD=1
    for function in $(_discord_builders); do
        rm -f "${TEST_TMP}/cmd_args"
        run --separate-stderr _call_builder "${function}"
        [ "${status}" -eq 0 ]
        [ "${output}" = '{"tool": "payload"}' ]
        [ "$(_call_builder "${function}" 2> /dev/null | od -An -tx1 | tr -d ' \n')" = "7b22746f6f6c223a20227061796c6f6164227d0a0a" ]
        expected=$(
            printf 'discord\npayload\n'
            jq -r --arg f "${function}" '.functions[$f] | .kind, (.options | to_entries[] | "--\(.value)\n\(.key + 1)")' \
                "${DISCORD_FIXTURE}"
            printf -- '---'
        )
        [ "$(sed -n '1,/^---$/p' "${TEST_TMP}/cmd_args")" = "${expected}" ]
        [ "${stderr}" = "tool stderr" ]
    done
}

@test "a lib/discord payload builder warns and builds the payload in bash when the tool refuses, fails or is missing (#252)" {
    local function result bash_payload exit_status
    _make_discord_cmd_stub
    for exit_status in 1 2 3 125; do
        _tool_answers 'partial output' "${exit_status}"
        for function in $(_discord_builders); do
            ORCHESTRATOR_DOTNET_DISCORD=0
            bash_payload=$(_call_builder "${function}")
            ORCHESTRATOR_DOTNET_DISCORD=1
            run --separate-stderr _call_builder "${function}"
            [ "${status}" -eq 0 ]
            [ "${output}" = "${bash_payload}" ]
            [[ "${stderr}" == *"fake-orchestrator discord payload "*" failed (exit ${exit_status}); building it in bash instead"* ]]
        done
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr build_discord_host_health_payload "Host Health: x" "message"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.embeds[0].description')" = message ]
    [[ "${stderr}" == *"discord payload host-health failed (exit 127); building it in bash instead"* ]]
}

@test "with ORCHESTRATOR_DOTNET_DISCORD on, the notifiers post the tool's payload and never hand it a webhook URL (#252)" {
    local args_log="${TEST_TMP}/curl_args"
    _make_discord_cmd_stub
    _tool_answers '{"from": "the tool"}' 0
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    set_repo_context "org/repo"
    ORCHESTRATOR_DOTNET_DISCORD=1
    DISCORD_WEBHOOK_URL="https://discord.example.com/api/webhooks/1/secret-token"
    DISCORD_WEBHOOK_URL_PERMISSIONS="https://discord.example.com/api/webhooks/2/other-token"
    run notify_discord_host_health "gpg_agent_down" "gpg-agent is not running"
    [ "${status}" -eq 0 ]
    run notify_discord_claude_error "Issue" "42" "Prompt is too long"
    [ "${status}" -eq 0 ]
    run notify_discord_permission_denials "PullRequest" "7" "- Bash: git push --force" 1
    [ "${status}" -eq 0 ]
    run notify_discord_rate_limited "Issue" "42" "429 Too Many Requests" 1764100800
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^{"from": "the tool"}$' "${args_log}")" -eq 4 ]
    [ "$(grep -c '^https://discord.example.com/api/webhooks/1/secret-token$' "${args_log}")" -eq 3 ]
    [ "$(grep -c '^https://discord.example.com/api/webhooks/2/other-token$' "${args_log}")" -eq 1 ]
    [ "$(grep -c '^---$' "${TEST_TMP}/cmd_args")" -eq 4 ]
    [ "$(grep -c 'token' "${TEST_TMP}/cmd_args")" -eq 0 ]
    grep -qx 'Rate Limited: org/repo' "${TEST_TMP}/cmd_args"
    grep -qx '<t:1764100800:t> (<t:1764100800:R>)' "${TEST_TMP}/cmd_args"
}
