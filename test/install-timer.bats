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

# Asserts the self-update ExecStartPre lines: the fetch step, and the merge step's
# retry-with-stale-lock-cleanup (#1298) — shared by both the default and --owner unit tests so
# the assertion is written once, not duplicated per test.
assert_selfupdate_execstartpre() {
    local svc="$1"
    grep -qE "ExecStartPre=-/usr/bin/timeout 60 .*/git -C .* fetch origin$" "${svc}"
    grep -qE 'ExecStartPre=-/usr/bin/timeout 30 /bin/sh -c .git -C .* merge --ff-only origin/main \|\| \{ find .*/\.git -name "\*\.lock" -delete; git -C .* merge --ff-only origin/main; \}.$' "${svc}"
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

@test "the merge ExecStartPre retry actually recovers from a stale nested lock file (#1298 regression, real repro)" {
    # Reproduces the exact failure the retry exists to recover from: a merge killed while
    # updating the branch ref leaves its lock at .git/refs/heads/<branch>.lock, not directly
    # under .git/ — a flat .git/*.lock glob (round 1 of this fix) would miss it entirely.
    local remote="${TEST_TMP}/retry-remote.git"
    local repo="${TEST_TMP}/retry-repo"
    git init --bare -q "${remote}"
    git -C "${remote}" symbolic-ref HEAD refs/heads/main
    git clone -q "${remote}" "${repo}"
    git -C "${repo}" config user.email "test@example.com"
    git -C "${repo}" config user.name "Test"
    git -C "${repo}" config core.hooksPath /dev/null
    git -C "${repo}" -c commit.gpgsign=false commit --allow-empty -m "init" >/dev/null 2>&1
    git -C "${repo}" push -q origin main

    local second_clone="${TEST_TMP}/retry-second-clone"
    git clone -q "${remote}" "${second_clone}"
    git -C "${second_clone}" config user.email "test@example.com"
    git -C "${second_clone}" config user.name "Test"
    git -C "${second_clone}" config core.hooksPath /dev/null
    git -C "${second_clone}" -c commit.gpgsign=false commit --allow-empty -m "second" >/dev/null 2>&1
    git -C "${second_clone}" push -q origin main
    git -C "${repo}" fetch -q origin

    touch "${repo}/.git/refs/heads/main.lock"

    # Generate the unit AGAINST this fixture repo — REPO_DIR is a plain global create_service_unit
    # reads, so overriding it here means the extracted ExecStartPre line already targets the
    # fixture directly; no text-surgery/retargeting needed.
    # shellcheck disable=SC2034 # consumed by create_service_unit, sourced from install-timer
    REPO_DIR="${repo}"
    run main
    [ "${status}" -eq 0 ]
    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"

    # "timeout 30 /bin/sh -c '" is unique to the merge-retry line — the unrelated gpg-agent
    # socket step a few lines below also matches a bare "/bin/sh -c '".
    local retry_cmd
    retry_cmd=$(grep -F "timeout 30 /bin/sh -c '" "${svc}")
    retry_cmd="${retry_cmd#*-c \'}"
    retry_cmd="${retry_cmd%\'}"

    run /bin/sh -c "${retry_cmd}"
    [ "${status}" -eq 0 ]
    [ ! -f "${repo}/.git/refs/heads/main.lock" ]

    run git -C "${repo}" rev-parse HEAD
    local head="${output}"
    run git -C "${repo}" rev-parse origin/main
    [ "${head}" = "${output}" ]
}

@test "install-timer creates unit files and invokes systemctl correctly" {
    run main
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    local tmr="${TEST_TMP}/units/credfeto-orchestrator-testuser.timer"

    [ -f "${svc}" ]
    grep -q "TimeoutStartSec=6300" "${svc}"
    grep -q "User=testuser" "${svc}"
    grep -q "RuntimeDirectory=credfeto-orchestrator-testuser" "${svc}"
    grep -q "RuntimeDirectoryMode=0700" "${svc}"
    grep -q "Delegate=cpu memory pids io" "${svc}"
    grep -q "Environment=XDG_RUNTIME_DIR=/run/user/1001" "${svc}"
    grep -q "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus" "${svc}"
    grep -q "Environment=SSH_AUTH_SOCK=/run/credfeto-orchestrator-testuser/ssh-agent.socket" "${svc}"
    assert_selfupdate_execstartpre "${svc}"
    grep -q "ExecStartPre=-/usr/bin/pkill -u testuser -f \"ssh-agent -a /run/credfeto-orchestrator-testuser/ssh-agent.socket\"" "${svc}"
    grep -q "ExecStartPre=-/usr/bin/rm -f /run/credfeto-orchestrator-testuser/ssh-agent.socket" "${svc}"
    grep -qE "ExecStartPre=.*/ssh-agent -a /run/credfeto-orchestrator-testuser/ssh-agent.socket$" "${svc}"
    grep -qE "ExecStartPre=.*/gpgconf --launch gpg-agent$" "${svc}"
    grep -q "ExecStartPre=-/usr/bin/pkill -u testuser gpg-agent" "${svc}"
    grep -qF "ExecStartPre=/bin/sh -c '/usr/bin/chmod 0660 \$(/usr/bin/gpgconf --list-dirs agent-extra-socket)'" "${svc}"
    grep -qE "ExecStart=.*/oneshot$" "${svc}"

    [ -f "${tmr}" ]
    grep -q "OnUnitActiveSec=${ORCHESTRATOR_TIMER_INTERVAL}" "${tmr}"
    grep -q "OnBootSec=${ORCHESTRATOR_TIMER_INTERVAL}" "${tmr}"

    [ -f "${TEST_TMP}/sudo.log" ]
    grep -q "systemctl daemon-reload" "${TEST_TMP}/sudo.log"
    grep -q "systemctl enable credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
    grep -q "systemctl start credfeto-orchestrator-testuser.timer" "${TEST_TMP}/sudo.log"
}

@test "install-timer service unit includes security hardening directives" {
    run main
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    [ -f "${svc}" ]
    # NoNewPrivileges must stay off and CAP_SETUID/CAP_SETGID must remain in the
    # bounding set, or rootless Podman's newuidmap/newgidmap helpers cannot map the
    # owner's subuid/subgid ranges ("newuidmap: Could not set caps").
    grep -q "NoNewPrivileges=no" "${svc}"
    # PrivateTmp must NOT be set: under it rootless Podman's persistent pause process
    # captures an empty private /var/tmp, breaking later image pulls.
    run grep -qE "^PrivateTmp=" "${svc}"
    [ "${status}" -ne 0 ]
    grep -q "ProtectSystem=full" "${svc}"
    grep -q "CapabilityBoundingSet=CAP_SETUID CAP_SETGID" "${svc}"
    # AmbientCapabilities stays empty so the service process holds no standing caps.
    grep -qE "^AmbientCapabilities=$" "${svc}"
    grep -q "LockPersonality=yes" "${svc}"
    grep -q "MemoryDenyWriteExecute=no" "${svc}"
}

@test "install-timer respects ORCHESTRATOR_TIMEOUT_START_SEC override (#1098)" {
    # shellcheck disable=SC2030,SC2031,SC2034  # read by create_service_unit in the sourced install-timer
    ORCHESTRATOR_TIMEOUT_START_SEC=1234
    run main
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    [ -f "${svc}" ]
    grep -q "TimeoutStartSec=1234" "${svc}"
}

@test "install-timer --owner creates owner-scoped unit files with --owner in ExecStart" {
    run main --owner myorg
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser-myorg.service"
    local tmr="${TEST_TMP}/units/credfeto-orchestrator-testuser-myorg.timer"

    [ -f "${svc}" ]
    grep -q "TimeoutStartSec=6300" "${svc}"
    grep -q "User=testuser" "${svc}"
    grep -q "RuntimeDirectory=credfeto-orchestrator-testuser-myorg" "${svc}"
    grep -q "RuntimeDirectoryMode=0700" "${svc}"
    grep -q "Delegate=cpu memory pids io" "${svc}"
    grep -q "Environment=XDG_RUNTIME_DIR=/run/user/1001" "${svc}"
    grep -q "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus" "${svc}"
    grep -q "Environment=SSH_AUTH_SOCK=/run/credfeto-orchestrator-testuser-myorg/ssh-agent.socket" "${svc}"
    assert_selfupdate_execstartpre "${svc}"
    grep -q "ExecStartPre=-/usr/bin/pkill -u testuser -f \"ssh-agent -a /run/credfeto-orchestrator-testuser-myorg/ssh-agent.socket\"" "${svc}"
    grep -q "ExecStartPre=-/usr/bin/rm -f /run/credfeto-orchestrator-testuser-myorg/ssh-agent.socket" "${svc}"
    grep -qE "ExecStartPre=.*/ssh-agent -a /run/credfeto-orchestrator-testuser-myorg/ssh-agent.socket$" "${svc}"
    grep -qE "ExecStartPre=.*/gpgconf --launch gpg-agent$" "${svc}"
    grep -q "ExecStartPre=-/usr/bin/pkill -u testuser gpg-agent" "${svc}"
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
