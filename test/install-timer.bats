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
    grep -qE 'ExecStartPre=-/usr/bin/timeout 30 /bin/sh -c .git -C .* merge --ff-only origin/main \|\| \{ find .*/\.git -name "\*\.lock" -mmin \+1 -delete; git -C .* merge --ff-only origin/main; \}.$' "${svc}"
}

# Asserts the ownership-heal ExecStartPre line (#1300/#1302): must run '+'-prefixed (forces root
# regardless of the unit's User=) combined with '-' (tolerate failure), and detect-then-chown the
# whole REPO_DIR tree using absolute /usr/bin/find and /usr/bin/chown paths, mirroring
# setup-owner's clone_or_pull_repo pattern. Repeats '-print -quit' on each side of -o rather than
# grouping with a \( -o \) (see install-timer) so this line never depends on how systemd's own
# Exec line parser handles an escape sequence it doesn't recognise.
assert_ownership_heal_execstartpre() {
    local svc="$1"
    grep -qE 'ExecStartPre=\+-/bin/sh -c .\[ -z "\$\(/usr/bin/find ".*" -not -user .* -print -quit -o -not -group .* -print -quit 2>/dev/null\)" \] \|\| /usr/bin/chown -R .*:.* ".*".$' "${svc}"
}

# Asserts the ownership-heal step (#1300/#1302) runs before the self-update fetch step, so a
# healed checkout is guaranteed to be in place before the merge that depends on it — a reorder
# would keep both assert_* greps above green while silently disabling the fix. Matching either
# marker and checking which one it is works because they're each unique to their own line: the
# first line in the file matching either pattern must be the heal line for this to pass.
assert_ownership_heal_before_selfupdate() {
    local svc="$1"
    grep -m1 -E 'ExecStartPre=\+-/bin/sh -c|ExecStartPre=-/usr/bin/timeout 60' "${svc}" | grep -q '+-/bin/sh -c'
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

# Extracts a single-quoted /bin/sh -c '...' command embedded in a generated unit file, given a
# grep marker unique to the target ExecStartPre line. Shared by selfupdate_retry_cmd_for and
# ownership_heal_cmd_for below, which differ only in how they configure the unit before
# generating it and which line's marker they pass in. Returns non-zero on a broken extraction
# (e.g. the grep stops matching after an install-timer change) rather than printing an empty
# string - callers must not embed this directly in `run /bin/sh -c "$(...)"`, since a command
# substitution's exit status is discarded there and an empty result would silently become
# `/bin/sh -c ""`, which always exits 0 and makes a no-drift-style test pass vacuously regardless
# of the real command's behaviour; use run_execstartpre_cmd below instead, which checks this.
extract_execstartpre_cmd() {
    local svc="$1" marker="$2"
    local cmd
    cmd=$(grep -F "${marker}" "${svc}")
    cmd="${cmd#*"${marker}"}"
    cmd="${cmd%\'}"
    [ -n "${cmd}" ] || return 1
    printf '%s' "${cmd}"
}

# Regenerates the systemd unit from whatever REPO_DIR/CURRENT_USER globals the caller has already
# set, then extracts the ExecStartPre command matching marker. Shared by selfupdate_retry_cmd_for
# and ownership_heal_cmd_for below, which differ only in which globals they override beforehand
# and which line's marker they pass in.
generated_execstartpre_cmd() {
    local marker="$1"
    main >/dev/null
    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    extract_execstartpre_cmd "${svc}" "${marker}"
}

# Asserts cmd (an already-extracted command from *_cmd_for) is non-empty before running it, then
# runs it via bats' `run`. Extraction failures must fail loudly here rather than at the call
# site: `run /bin/sh -c "$(foo)"` discards the command substitution's own exit status, so an
# empty extraction would otherwise silently become the always-succeeding `/bin/sh -c ""`.
run_execstartpre_cmd() {
    local cmd="$1"
    [ -n "${cmd}" ]
    run /bin/sh -c "${cmd}"
}

# Extracts the merge-retry ExecStartPre command for repo_dir as a plain string, ready for
# `run /bin/sh -c "$(...)"`. Shared by the two regression tests below. REPO_DIR is a plain global
# create_service_unit reads, so overriding it here means the extracted line already targets
# repo_dir directly — no text-surgery/retargeting needed.
selfupdate_retry_cmd_for() {
    local repo_dir="$1"
    # shellcheck disable=SC2034 # consumed by create_service_unit, sourced from install-timer
    REPO_DIR="${repo_dir}"
    # "timeout 30 /bin/sh -c '" is unique to the merge-retry line — the unrelated gpg-agent socket
    # step a few lines below also matches a bare "/bin/sh -c '".
    generated_execstartpre_cmd "timeout 30 /bin/sh -c '"
}

@test "the merge ExecStartPre retry actually recovers from a stale nested lock file (#1298 regression, real repro)" {
    # Reproduces the exact failure the retry exists to recover from: a merge killed while
    # updating the branch ref leaves its lock at .git/refs/heads/<branch>.lock, not directly
    # under .git/ — a flat .git/*.lock glob would miss it entirely.
    local repo="${TEST_TMP}/retry-repo"
    local remote
    remote=$(setup_local_git_remote "${repo}")
    advance_remote_main "${remote}" 1
    git -C "${repo}" fetch -q origin

    # A lock from a process killed well before this tick — old enough that the age gate (-mmin
    # +1, comfortably above the step's own 30-second timeout) must treat it as safe to clear.
    touch -d '-10 minutes' "${repo}/.git/refs/heads/main.lock"

    run_execstartpre_cmd "$(selfupdate_retry_cmd_for "${repo}")"
    [ "${status}" -eq 0 ]
    [ ! -f "${repo}/.git/refs/heads/main.lock" ]

    run git -C "${repo}" rev-parse HEAD
    local head="${output}"
    run git -C "${repo}" rev-parse origin/main
    [ "${head}" = "${output}" ]
}

@test "the merge ExecStartPre retry does NOT clear a fresh lock (#1298 review — must not race a sibling --owner unit's in-flight merge)" {
    # REPO_DIR is the SAME checkout for every --owner variant installed for this user (#1298
    # review). Without the age gate, this retry would delete a lock a DIFFERENT, concurrently-
    # running unit's merge is still legitimately holding, racing it. A fresh-mtime lock here
    # stands in for exactly that in-flight-elsewhere case.
    local repo="${TEST_TMP}/retry-fresh-repo"
    local remote
    remote=$(setup_local_git_remote "${repo}")
    advance_remote_main "${remote}" 1
    git -C "${repo}" fetch -q origin

    touch "${repo}/.git/refs/heads/main.lock"

    run_execstartpre_cmd "$(selfupdate_retry_cmd_for "${repo}")"
    [ "${status}" -ne 0 ]
    [ -f "${repo}/.git/refs/heads/main.lock" ]

    # The merge itself must still be reported as failed (tolerated by the '-' ExecStartPre
    # prefix), not silently swallowed, and origin/main must NOT have been merged in.
    run git -C "${repo}" rev-parse HEAD
    local head="${output}"
    run git -C "${repo}" rev-parse origin/main
    [ "${head}" != "${output}" ]
}

# Extracts the ownership-heal ExecStartPre command for repo_dir/current_user as a plain string,
# ready for `run /bin/sh -c "$(...)"`. CURRENT_USER is overridden as a plain global the same way
# selfupdate_retry_cmd_for overrides REPO_DIR above — this bypasses the file-level `id` stub
# (which returns the unresolvable name "testuser") so the extracted command's `find -user`/
# `-group` arguments name a real, resolvable account, since a nonexistent username makes find
# itself error out rather than exercise the detect logic.
ownership_heal_cmd_for() {
    local repo_dir="$1" current_user="$2"
    # shellcheck disable=SC2034 # consumed by create_service_unit, sourced from install-timer
    REPO_DIR="${repo_dir}"
    # shellcheck disable=SC2034 # consumed by create_service_unit, sourced from install-timer
    CURRENT_USER="${current_user}"
    generated_execstartpre_cmd "ExecStartPre=+-/bin/sh -c '"
}

# Creates a minimal repo checkout (just enough for the ownership-heal find/chown command to have
# something to walk) at the given path, shared by the two ownership-heal regression tests below.
make_fake_repo() {
    local repo="$1"
    mkdir -p "${repo}/.git"
    touch "${repo}/.git/index"
}

@test "the ownership-heal ExecStartPre is a no-op when nothing is owned by a different user (#1300/#1302, real repro)" {
    # command bypasses the file-level `id` shell-function stub to get the real account running
    # this test, so the extracted find/chown command's CURRENT_USER matches the temp repo's
    # actual on-disk owner and genuinely exercises the no-drift path, not a forced pass.
    local real_user
    real_user=$(command id -un)

    local repo="${TEST_TMP}/heal-no-drift-repo"
    make_fake_repo "${repo}"

    run_execstartpre_cmd "$(ownership_heal_cmd_for "${repo}" "${real_user}")"
    [ "${status}" -eq 0 ]
}

@test "the ownership-heal ExecStartPre detects drift and attempts to reassert ownership (#1300/#1302, real repro)" {
    # Every file under repo is genuinely owned by the account running this test, not by root, so
    # naming "root" as CURRENT_USER reproduces real drift (analogous to #1300's root-run
    # diagnostic command reowning .git/index) without needing privilege to actually chown a file
    # away from its real owner. The chown this triggers then genuinely fails with "Operation not
    # permitted" — this test is run unprivileged deliberately, so it proves the detect-then-chown
    # branch was taken (the exact command the '+' prefix lets systemd run as root in production)
    # without asserting on privileged behaviour this suite cannot grant itself. If the suite itself
    # is somehow run as root (e.g. a container-based CI runner), naming "root" as CURRENT_USER
    # would never look like drift and the chown would genuinely succeed, so skip rather than fail.
    if [ "$(command id -u)" -eq 0 ]; then
        skip "requires an unprivileged test runner to reproduce ownership drift"
    fi

    local repo="${TEST_TMP}/heal-drift-repo"
    make_fake_repo "${repo}"

    LC_ALL=C run_execstartpre_cmd "$(ownership_heal_cmd_for "${repo}" "root")"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Operation not permitted"* ]]

    # The failed, unprivileged chown must not have silently succeeded in any partial form: the
    # repo's actual owner (this test's own account) must be unchanged.
    run find "${repo}" -not -user "$(command id -un)" -print -quit
    [ -z "${output}" ]
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
    grep -q "Environment=ORCHESTRATOR_SELF_UPDATE_MANAGED=1" "${svc}"
    assert_ownership_heal_execstartpre "${svc}"
    assert_ownership_heal_before_selfupdate "${svc}"
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
    grep -q "Environment=ORCHESTRATOR_SELF_UPDATE_MANAGED=1" "${svc}"
    assert_ownership_heal_execstartpre "${svc}"
    assert_ownership_heal_before_selfupdate "${svc}"
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
