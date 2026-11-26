#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_AGENTS (#252): off by default; when on, ssh_agent_key_state asks ORCHESTRATOR_CMD agent
# ssh-key-state, takes its answer when it gives one (exit 0, 1, or 4 for ssh-add's 2) and runs ssh-add, with a
# warning, when it does not. test/oneshot-agents-parity.bats checks what both sides return.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# A stand-in for the tool: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---), writes "tool output"
# to stdout and "tool stderr" to stderr, and exits with ${TEST_TMP}/status (0 when absent)
make_agents_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'printf "tool output\n"' \
        'printf "tool stderr\n" >&2' \
        'if [ -f "${TEST_TMP}/status" ]; then exit "$(cat "${TEST_TMP}/status")"; fi' \
        'exit 0'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

# An ssh-add that logs its arguments to ${TEST_TMP}/ssh_add_args, writes to both streams, and exits with
# ${TEST_TMP}/ssh_add_status (1 when absent) for -l and 0 for anything else
make_ssh_add_stub() {
    make_stub ssh-add 'printf "%s\n" "$*" >> "${TEST_TMP}/ssh_add_args"
        printf "ssh-add output\n"
        printf "ssh-add stderr\n" >&2
        if [ "$1" = "-l" ]; then
            if [ -f "${TEST_TMP}/ssh_add_status" ]; then exit "$(cat "${TEST_TMP}/ssh_add_status")"; fi
            exit 1
        fi
        exit 0'
}

_tool_exits() {
    printf '%s' "$1" > "${TEST_TMP}/status"
}

# Runs ssh_agent_key_state and prints what it wrote to stdout, then its status after a dot
_key_state() {
    ssh_agent_key_state
    printf '.%s' "$?"
}

@test "ORCHESTRATOR_DOTNET_AGENTS defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_AGENTS bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_AGENTS}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "ssh_agent_key_state never runs ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_AGENTS is off (#252)" {
    make_agents_cmd_stub
    make_ssh_add_stub
    ORCHESTRATOR_DOTNET_AGENTS=0
    export SSH_AUTH_SOCK="${TEST_TMP}/agent.sock"
    local status_code
    for status_code in 0 1 2 127; do
        printf '%s' "${status_code}" > "${TEST_TMP}/ssh_add_status"
        run --separate-stderr _key_state
        [ "${output}" = ".${status_code}" ]
        [ -z "${stderr}" ]
    done
    [ ! -f "${TEST_TMP}/cmd_args" ]
    [ "$(cat "${TEST_TMP}/ssh_add_args")" = $'-l\n-l\n-l\n-l' ]
}

@test "ssh_agent_key_state hands the socket to ORCHESTRATOR_CMD agent ssh-key-state when switched on (#252)" {
    make_agents_cmd_stub
    make_ssh_add_stub
    ORCHESTRATOR_DOTNET_AGENTS=1
    export SSH_AUTH_SOCK="${TEST_TMP}/a dir/--socket"
    _tool_exits 1
    run --separate-stderr _key_state
    [ "${output}" = ".1" ]
    [ -z "${stderr}" ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = "agent
ssh-key-state
--socket
${TEST_TMP}/a dir/--socket
---" ]
    [ ! -f "${TEST_TMP}/ssh_add_args" ]
}

@test "ssh_agent_key_state returns the tool's 0 and 1, and ssh-add's 2 for the tool's 4, printing nothing (#252)" {
    make_agents_cmd_stub
    make_ssh_add_stub
    ORCHESTRATOR_DOTNET_AGENTS=1
    export SSH_AUTH_SOCK="${TEST_TMP}/agent.sock"
    local answer
    for answer in 0:0 1:1 4:2; do
        _tool_exits "${answer%%:*}"
        run --separate-stderr _key_state
        [ "${output}" = ".${answer##*:}" ]
        [ -z "${stderr}" ]
    done
    [ ! -f "${TEST_TMP}/ssh_add_args" ]
}

@test "ssh_agent_key_state warns and asks ssh-add when the tool gives no answer (#252)" {
    make_agents_cmd_stub
    make_ssh_add_stub
    ORCHESTRATOR_DOTNET_AGENTS=1
    export SSH_AUTH_SOCK="${TEST_TMP}/agent.sock"
    printf '2' > "${TEST_TMP}/ssh_add_status"
    local tool_status
    for tool_status in 2 3 125 126 130; do
        _tool_exits "${tool_status}"
        run --separate-stderr _key_state
        [ "${output}" = ".2" ]
        [ "${stderr}" = "! fake-orchestrator agent ssh-key-state failed (exit ${tool_status}); asking ssh-add in bash instead" ]
    done
    [ "$(cat "${TEST_TMP}/ssh_add_args")" = $'-l\n-l\n-l\n-l\n-l' ]
}

@test "ssh_agent_key_state asks ssh-add when ORCHESTRATOR_CMD is missing (#252)" {
    make_ssh_add_stub
    ORCHESTRATOR_DOTNET_AGENTS=1
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    export SSH_AUTH_SOCK="${TEST_TMP}/agent.sock"
    printf '0' > "${TEST_TMP}/ssh_add_status"
    run --separate-stderr _key_state
    [ "${output}" = ".0" ]
    [[ "${stderr}" == *"no-such-tool agent ssh-key-state failed (exit 127); asking ssh-add in bash instead" ]]
    [ "$(cat "${TEST_TMP}/ssh_add_args")" = "-l" ]
}

@test "ssh_agent_key_state leaves an unset or empty SSH_AUTH_SOCK to ssh-add when switched on (#252)" {
    make_agents_cmd_stub
    make_ssh_add_stub
    ORCHESTRATOR_DOTNET_AGENTS=1
    printf '2' > "${TEST_TMP}/ssh_add_status"
    unset SSH_AUTH_SOCK
    run --separate-stderr _key_state
    [ "${output}" = ".2" ]
    export SSH_AUTH_SOCK=""
    run --separate-stderr _key_state
    [ "${output}" = ".2" ]
    [ -z "${stderr}" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
    [ "$(cat "${TEST_TMP}/ssh_add_args")" = $'-l\n-l' ]
}

@test "preload_ssh_keys takes the tool's answers when switched on (#252)" {
    make_agents_cmd_stub
    make_ssh_add_stub
    ORCHESTRATOR_DOTNET_AGENTS=1
    local ssh_sock="${TEST_TMP}/ssh-agent.sock" discord_log="${TEST_TMP}/discord.log"
    python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "${ssh_sock}"
    export SSH_AUTH_SOCK="${ssh_sock}"
    notify_discord_host_health() { printf '%s\n' "$*" >> "${discord_log}"; }

    _tool_exits 0
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/ssh_add_args" ]

    _tool_exits 1
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
    [ "$(cat "${TEST_TMP}/ssh_add_args")" = "-q" ]

    _tool_exits 4
    run preload_ssh_keys
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot connect to the agent"* ]]
    grep -q "ssh_agent_down" "${discord_log}"
    [ "$(cat "${TEST_TMP}/ssh_add_args")" = "-q" ]
}
