#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_DISCORD (#252): off by default; when on, the lib/discord payload builders ask
# ORCHESTRATOR_CMD discord payload <kind> for the payload, print it when the tool gives one (exit 0) and build it in
# bash, with a warning, when it does not. Posting the payload stays in bash, and the webhook URL never reaches the
# tool. test/oneshot-discord-parity.bats checks what both sides print. The text functions record_item_status,
# serialize_item_status_log, _build_no_work_item_breakdown and truncate_for_display likewise ask
# ORCHESTRATOR_CMD discord item-status|item-status-log|no-work-breakdown|truncate, handing long input over on stdin;
# test/oneshot-discord-text-parity.bats checks what both sides print.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

DISCORD_FIXTURES=(
    "${BATS_TEST_DIRNAME}/fixtures/discord-parity.json"
    "${BATS_TEST_DIRNAME}/fixtures/discord-stalled-digest-parity.json"
)

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

# Every builder's kind and options, from the fixtures (test/oneshot-discord-parity.bats checks they list every one in
# lib/discord)
_discord_functions() {
    jq -s 'map(.functions) | add' "${DISCORD_FIXTURES[@]}"
}

_discord_builders() {
    _discord_functions | jq -r 'keys[]'
}

# The argument builder $1 is given for each option: the Nth is N, a valid number and text alike, or null for an
# option whose value is JSON
_builder_arguments() {
    _discord_functions | jq -r --arg f "$1" \
        '.[$f] | (.json // []) as $json | .options | to_entries[] | if (.value | IN($json[])) then "null" else .key + 1 end'
}

# Runs builder $1 with _builder_arguments
_call_builder() {
    local args=()
    mapfile -t args < <(_builder_arguments "$1")
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
            _discord_functions | jq -r --arg f "${function}" '.[$f].kind'
            paste -d '\n' <(_discord_functions | jq -r --arg f "${function}" '.[$f].options[] | "--" + .') \
                <(_builder_arguments "${function}")
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
    # Four payloads, and the permission-denials summary truncate_for_display hands the tool before its payload
    [ "$(grep -c '^---$' "${TEST_TMP}/cmd_args")" -eq 5 ]
    grep -qx 'truncate' "${TEST_TMP}/cmd_args"
    [ "$(grep -c 'token' "${TEST_TMP}/cmd_args")" -eq 0 ]
    grep -qx 'Rate Limited: org/repo' "${TEST_TMP}/cmd_args"
    grep -qx '<t:1764100800:t> (<t:1764100800:R>)' "${TEST_TMP}/cmd_args"
}

@test "with ORCHESTRATOR_DOTNET_DISCORD on, the session-stalled and daily digest notifiers post the tool's payload (#252)" {
    local args_log="${TEST_TMP}/curl_args"
    _make_discord_cmd_stub
    _tool_answers '{"from": "the tool"}' 0
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    set_repo_context "org/repo"
    ORCHESTRATOR_DOTNET_DISCORD=1
    DISCORD_WEBHOOK_URL="https://discord.example.com/api/webhooks/1/secret-token"
    DISCORD_WEBHOOK_URL_PERMISSIONS="https://discord.example.com/api/webhooks/2/other-token"
    run notify_discord_session_stalled "PullRequest" "7" "3" "gh,git" "stopped at /home/someone/notes.txt"
    [ "${status}" -eq 0 ]
    run notify_discord_daily_digest "org" "2026-10-04" '{"sessions":1}' ""
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^{"from": "the tool"}$' "${args_log}")" -eq 2 ]
    [ "$(grep -c '^https://discord.example.com/api/webhooks/2/other-token$' "${args_log}")" -eq 2 ]
    [ "$(grep -c 'token' "${TEST_TMP}/cmd_args")" -eq 0 ]
    [ "$(sed -n '1,/^---$/p' "${TEST_TMP}/cmd_args")" = "$(printf '%s\n' discord payload session-stalled \
        --repository org/repo --item 'PullRequest #7' --url https://github.com/org/repo/pull/7 --count 3 \
        --commands gh,git --message 'stopped at /home/someone/notes.txt' ---)" ]
    [ "$(sed -n '/^---$/,$p' "${TEST_TMP}/cmd_args" | sed 1d)" = "$(printf '%s\n' discord payload daily-digest \
        --owner org --day 2026-10-04 --summary '{"sessions":1}' --previous null ---)" ]
}

@test "with ORCHESTRATOR_DOTNET_DISCORD on, a daily digest the tool refuses is built and posted from bash (#252)" {
    local payload_file="${TEST_TMP}/payload.json"
    _make_discord_cmd_stub
    _tool_answers '' 3
    make_stub curl "while [ \"\$#\" -gt 0 ]; do if [ \"\$1\" = -d ]; then printf '%s' \"\$2\" > '${payload_file}'; fi; shift; done"
    ORCHESTRATOR_DOTNET_DISCORD=1
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    run --separate-stderr notify_discord_daily_digest "org" "2026-10-04" '{"sessions": 1.5, "repos": [], "top_commands": []}' "null"
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"discord payload daily-digest failed (exit 3); building it in bash instead"* ]]
    [ "$(jq -r '.embeds[0].fields[0].value' "${payload_file}")" = "1.5 (no record for the day before)" ]
}

# A stand-in for the tool for the text commands: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---),
# saves its stdin as ${TEST_TMP}/stdin-<command>, writes "tool stderr" to stderr, prints ${TEST_TMP}/answer-<command>
# and exits with ${TEST_TMP}/status-<command> (0 when absent)
_make_discord_text_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'cat > "${TEST_TMP}/stdin-$2"' \
        'printf "tool stderr\n" >&2' \
        'if [ -f "${TEST_TMP}/answer-$2" ]; then cat "${TEST_TMP}/answer-$2"; fi' \
        'if [ -f "${TEST_TMP}/status-$2" ]; then exit "$(cat "${TEST_TMP}/status-$2")"; fi' \
        'exit 0'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

# Each text function with a typical argument list, one call a line, for eval
_discord_text_calls() {
    printf '%s\n' \
        'record_item_status Issue 42 org/repo "blocked - skipping"' \
        'serialize_item_status_log "{\"type\":\"Issue\"}" "{\"id\":\"1\"}"' \
        '_build_no_work_item_breakdown "[{\"type\":\"Issue\",\"id\":\"1\",\"repo\":\"o/r\",\"reason\":\"x\"}]"' \
        'truncate_for_display "some text" 4'
}

@test "the lib/discord text functions never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_DISCORD is off (#252)" {
    local call
    _make_discord_text_cmd_stub
    ORCHESTRATOR_DOTNET_DISCORD=0
    while IFS= read -r call; do
        run --separate-stderr eval "${call}"
        [ "${status}" -eq 0 ]
        [ -n "${output}" ]
        [ -z "${stderr}" ]
    done < <(_discord_text_calls)
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "each lib/discord text function hands its command, options and stdin to ORCHESTRATOR_CMD and prints its answer as it is (#252)" {
    local command
    _make_discord_text_cmd_stub
    for command in item-status item-status-log no-work-breakdown truncate; do
        printf 'tool %s\n\n' "${command}" > "${TEST_TMP}/answer-${command}"
    done
    set_repo_context "fallback/repo"
    ORCHESTRATOR_DOTNET_DISCORD=1

    [ "$(record_item_status Issue 42 org/repo "blocked - skipping" 2> /dev/null | od -An -tx1 | tr -d ' \n')" = \
        "$(printf 'tool item-status\n\n' | od -An -tx1 | tr -d ' \n')" ]
    [ "$(sed -n '1,/^---$/p' "${TEST_TMP}/cmd_args")" = "$(printf '%s\n' discord item-status --type Issue --id 42 \
        --repo org/repo --reason 'blocked - skipping' ---)" ]
    [ ! -s "${TEST_TMP}/stdin-item-status" ]

    rm -f "${TEST_TMP}/cmd_args"
    run --separate-stderr serialize_item_status_log '{"type":"Issue"}' '' '{"id":"1"}'
    [ "${status}" -eq 0 ]
    [ "${output}" = "tool item-status-log" ]
    [ "${stderr}" = "tool stderr" ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = "$(printf '%s\n' discord item-status-log ---)" ]
    cmp "${TEST_TMP}/stdin-item-status-log" <(printf '{"type":"Issue"}\n\n{"id":"1"}\n\n')

    rm -f "${TEST_TMP}/cmd_args"
    LC_ALL=C.UTF-8
    run --separate-stderr _build_no_work_item_breakdown '[{"type":"Issue"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "tool no-work-breakdown" ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = "$(printf '%s\n' discord no-work-breakdown --default-repo fallback/repo \
        --length-unit characters ---)" ]
    cmp "${TEST_TMP}/stdin-no-work-breakdown" <(printf '[{"type":"Issue"}]\n')
    rm -f "${TEST_TMP}/cmd_args"
    LC_ALL=C
    run --separate-stderr _build_no_work_item_breakdown '[]'
    [ "${status}" -eq 0 ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = "$(printf '%s\n' discord no-work-breakdown --default-repo fallback/repo \
        --length-unit bytes ---)" ]

    rm -f "${TEST_TMP}/cmd_args"
    run --separate-stderr truncate_for_display $'line one\n\n'
    [ "${status}" -eq 0 ]
    [ "${output}" = "tool truncate" ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = "$(printf '%s\n' discord truncate --max-length 900 ---)" ]
    cmp "${TEST_TMP}/stdin-truncate" <(printf 'line one\n\n\n')
}

@test "serialize_item_status_log with no entries prints [] without asking ORCHESTRATOR_CMD (#252)" {
    _make_discord_text_cmd_stub
    ORCHESTRATOR_DOTNET_DISCORD=1
    run --separate-stderr serialize_item_status_log
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
    [ -z "${stderr}" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "a lib/discord text function warns and runs its bash when the tool refuses, fails or is missing (#252)" {
    local call command exit_status expected
    _make_discord_text_cmd_stub
    set_repo_context "fallback/repo"
    for exit_status in 1 2 3 125; do
        for command in item-status item-status-log no-work-breakdown truncate; do
            printf 'partial output' > "${TEST_TMP}/answer-${command}"
            printf '%s' "${exit_status}" > "${TEST_TMP}/status-${command}"
        done
        while IFS= read -r call; do
            ORCHESTRATOR_DOTNET_DISCORD=0
            expected=$(eval "${call}")
            ORCHESTRATOR_DOTNET_DISCORD=1
            run --separate-stderr eval "${call}"
            [ "${status}" -eq 0 ]
            [ "${output}" = "${expected}" ]
            [[ "${stderr}" == *"fake-orchestrator discord "*" failed (exit ${exit_status}); running it in bash instead"* ]]
        done < <(_discord_text_calls)
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr truncate_for_display "abcdef" 3
    [ "${status}" -eq 0 ]
    [ "${output}" = $'abc\n... (truncated; see the run log for the full list)' ]
    [[ "${stderr}" == *"discord truncate failed (exit 127); running it in bash instead"* ]]
}

@test "with ORCHESTRATOR_DOTNET_DISCORD on, notify_discord_no_work posts the breakdown the tool builds (#252)" {
    local payload_file="${TEST_TMP}/payload.json"
    _make_discord_text_cmd_stub
    printf -- '- the tool breakdown' > "${TEST_TMP}/answer-no-work-breakdown"
    printf '3' > "${TEST_TMP}/status-payload"
    make_stub curl "while [ \"\$#\" -gt 0 ]; do if [ \"\$1\" = -d ]; then printf '%s' \"\$2\" > '${payload_file}'; fi; shift; done"
    ORCHESTRATOR_DOTNET_DISCORD=1
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    run --separate-stderr notify_discord_no_work "org" 1 0 0 0 0 0 '[{"type":"Issue","id":"1","repo":"o/r","reason":"x"}]'
    [ "${status}" -eq 0 ]
    [ "$(jq -r '.embeds[0].description' "${payload_file}")" = "- the tool breakdown" ]
    [ "$(jq -r '.embeds[0].title' "${payload_file}")" = "[org] No actionable work items found. (blocked: 1)" ]
    cmp "${TEST_TMP}/stdin-no-work-breakdown" <(printf '[{"type":"Issue","id":"1","repo":"o/r","reason":"x"}]\n')
    grep -qx 'https://discord.example.com/hook' "${TEST_TMP}/cmd_args" && return 1
    return 0
}
