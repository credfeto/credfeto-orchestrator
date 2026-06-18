#!/usr/bin/env bats

load test_helper

setup() {
    setup_isolated_env

    mkdir -p "${TEST_TMP}/units"
    make_stub systemctl 'exit 0'

    # Override id as a bash function so CURRENT_USER and current_uid resolve to
    # predictable test values when install-timer is sourced.  Both functions must
    # be exported so command substitution subshells in the script see them.
    # shellcheck disable=SC2329
    id() {
        case "$*" in
            -un) echo "testuser" ;;
            -u)  echo "1001" ;;
            *)   echo "testuser" ;;
        esac
    }
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

teardown() {
    cleanup_stubs
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
    grep -q "RuntimeDirectory=credfeto-orchestrator-testuser" "${svc}"
    grep -q "RuntimeDirectoryMode=0700" "${svc}"
    grep -q "Delegate=yes" "${svc}"
    grep -q "Environment=XDG_RUNTIME_DIR=/run/user/1001" "${svc}"
    grep -q "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus" "${svc}"
    grep -q "Environment=SSH_AUTH_SOCK=/run/credfeto-orchestrator-testuser/ssh-agent.socket" "${svc}"
    grep -qE "ExecStartPre=.*/git -C .* fetch origin$" "${svc}"
    grep -qE "ExecStartPre=.*/git -C .* merge --ff-only origin/main$" "${svc}"
    grep -q "ExecStartPre=-/usr/bin/rm -f /run/credfeto-orchestrator-testuser/ssh-agent.socket" "${svc}"
    grep -qE "ExecStartPre=.*/ssh-agent -a /run/credfeto-orchestrator-testuser/ssh-agent.socket$" "${svc}"
    grep -qE "ExecStartPre=.*/gpgconf --launch gpg-agent$" "${svc}"
    grep -qF "ExecStartPre=/bin/sh -c '/usr/bin/chmod 0660 \$(/usr/bin/gpgconf --list-dirs agent-extra-socket)'" "${svc}"
    grep -qE "ExecStart=.*/oneshot$" "${svc}"

    [ -f "${tmr}" ]
    grep -q "OnUnitActiveSec=5min" "${tmr}"
    grep -q "OnBootSec=5min" "${tmr}"

    [ -f "${TEST_TMP}/sudo.log" ]
    grep -q "systemctl daemon-reload" "${TEST_TMP}/sudo.log"
    grep -q "systemctl enable credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
    grep -q "systemctl start credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
}

@test "install-timer --owner creates owner-scoped unit files with --owner in ExecStart" {
    run main --owner myorg
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser-myorg.service"
    local tmr="${TEST_TMP}/units/credfeto-orchestrator-testuser-myorg.timer"

    [ -f "${svc}" ]
    grep -q "User=testuser" "${svc}"
    grep -q "RuntimeDirectory=credfeto-orchestrator-testuser-myorg" "${svc}"
    grep -q "RuntimeDirectoryMode=0700" "${svc}"
    grep -q "Delegate=yes" "${svc}"
    grep -q "Environment=XDG_RUNTIME_DIR=/run/user/1001" "${svc}"
    grep -q "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus" "${svc}"
    grep -q "Environment=SSH_AUTH_SOCK=/run/credfeto-orchestrator-testuser-myorg/ssh-agent.socket" "${svc}"
    grep -qE "ExecStartPre=.*/git -C .* fetch origin$" "${svc}"
    grep -qE "ExecStartPre=.*/git -C .* merge --ff-only origin/main$" "${svc}"
    grep -q "ExecStartPre=-/usr/bin/rm -f /run/credfeto-orchestrator-testuser-myorg/ssh-agent.socket" "${svc}"
    grep -qE "ExecStartPre=.*/ssh-agent -a /run/credfeto-orchestrator-testuser-myorg/ssh-agent.socket$" "${svc}"
    grep -qE "ExecStartPre=.*/gpgconf --launch gpg-agent$" "${svc}"
    grep -qF "ExecStartPre=/bin/sh -c '/usr/bin/chmod 0660 \$(/usr/bin/gpgconf --list-dirs agent-extra-socket)'" "${svc}"
    grep -qE "ExecStart=.*/oneshot --owner myorg$" "${svc}"

    [ -f "${tmr}" ]
    grep -q "Unit=credfeto-orchestrator-testuser-myorg.service" "${tmr}"

    [ -f "${TEST_TMP}/sudo.log" ]
    grep -q "systemctl enable credfeto-orchestrator-testuser-myorg.timer" "${TEST_TMP}/sudo.log"
    grep -q "systemctl start credfeto-orchestrator-testuser-myorg.timer" "${TEST_TMP}/sudo.log"
}

@test "install-timer --owner with no value dies" {
    run main --owner
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--owner requires a value"* ]]
}

@test "install-timer with an unknown argument dies" {
    run main --unknown-flag
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument"* ]]
}

@test "install-timer --owner with invalid characters dies" {
    run main --owner "evil;cmd"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid characters"* ]]
}
