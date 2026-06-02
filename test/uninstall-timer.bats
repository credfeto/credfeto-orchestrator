#!/usr/bin/env bats

load test_helper

setup() {
    setup_isolated_env

    # shellcheck disable=SC2329
    id() { echo "testuser"; }
    export -f id

    unset CLAUDECODE

    source_uninstall_timer

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
    }
    export -f sudo
}

@test "sourcing uninstall-timer defines main without executing it" {
    run declare -F main
    [ "${status}" -eq 0 ]
    run declare -F is_ai_agent
    [ "${status}" -eq 0 ]
}

@test "is_ai_agent returns true when CLAUDECODE=1 and false otherwise" {
    CLAUDECODE=1 run is_ai_agent
    [ "${status}" -eq 0 ]
    CLAUDECODE=0 run is_ai_agent
    [ "${status}" -ne 0 ]
}

@test "uninstall-timer dies when run inside a Claude Code session" {
    CLAUDECODE=1 run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not be run inside a Claude Code session"* ]]
}

@test "check_required_tools dies when a required tool is missing" {
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "systemctl" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found"* ]]
}

@test "uninstall-timer stops disables removes unit files and reloads systemd daemon" {
    run main
    [ "${status}" -eq 0 ]

    [ -f "${TEST_TMP}/sudo.log" ]
    grep -q "systemctl stop credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
    grep -q "systemctl disable credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
    grep -q "rm -f.*credfeto-orchestrator-testuser.service" "${TEST_TMP}/sudo.log"
    grep -q "rm -f.*credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
    grep -q "systemctl daemon-reload" "${TEST_TMP}/sudo.log"
}

@test "uninstall-timer issues stop and disable before removing unit files" {
    run main
    [ "${status}" -eq 0 ]

    local stop_line rm_line reload_line
    stop_line=$(grep -n "systemctl stop" "${TEST_TMP}/sudo.log" | cut -d: -f1)
    rm_line=$(grep -n "^rm -f" "${TEST_TMP}/sudo.log" | cut -d: -f1)
    reload_line=$(grep -n "systemctl daemon-reload" "${TEST_TMP}/sudo.log" | cut -d: -f1)
    [ "${stop_line}" -lt "${rm_line}" ]
    [ "${rm_line}" -lt "${reload_line}" ]
}
