#!/usr/bin/env bats

load test_helper

setup() {
    setup_isolated_env

    mkdir -p "${TEST_TMP}/units"

    # Override id as a bash function so CURRENT_USER resolves to "testuser"
    # when install-timer is sourced.  The function must be exported so that
    # command substitution subshells in the script see it.
    # shellcheck disable=SC2329
    id() { echo "testuser"; }
    export -f id

    unset CLAUDECODE

    source_install_timer

    # Override sudo as a bash function to record calls and handle tee in-process.
    # The tee case rewrites the destination from /etc/systemd/system/ to the
    # test-controlled units directory so no real root writes occur.
    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            tee)
                shift
                local dest="$1"
                local redirected="${TEST_TMP}/units/${dest##*/}"
                tee "${redirected}"
                ;;
        esac
    }
    export -f sudo

}

@test "sourcing install-timer defines main without executing it" {
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

@test "install-timer dies when run inside a Claude Code session" {
    CLAUDECODE=1 run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not be run inside a Claude Code session"* ]]
}

@test "check_required_tools dies when a required tool is missing" {
    # Override the shell builtin used for presence checks so that git
    # reports as absent, deterministically and without altering the real system.
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "git" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found"* ]]
}

@test "install-timer creates unit files and invokes systemctl correctly" {
    run main
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    local tmr="${TEST_TMP}/units/credfeto-orchestrator-testuser.timer"

    [ -f "${svc}" ]
    grep -q "User=testuser" "${svc}"
    grep -qE "ExecStart=.*/oneshot" "${svc}"

    [ -f "${tmr}" ]
    grep -q "OnUnitActiveSec=5min" "${tmr}"
    grep -q "OnBootSec=5min" "${tmr}"

    [ -f "${TEST_TMP}/sudo.log" ]
    grep -q "systemctl daemon-reload" "${TEST_TMP}/sudo.log"
    grep -q "systemctl enable credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
    grep -q "systemctl start credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
}
