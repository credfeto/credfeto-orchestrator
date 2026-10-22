#!/usr/bin/env bats

load test_helper

setup() {
    setup_isolated_env

    mkdir -p "${TEST_TMP}/units"
    make_stub systemctl "printf 'systemctl %s\\n' \"\$*\" >> '${TEST_TMP}/systemctl.log'"

    # Override id as a bash function so the unit user's uid resolves to a predictable test value.
    # It must be exported so command substitution subshells in the library see it.
    # shellcheck disable=SC2329
    id() {
        case "$1" in
            -un) echo "testuser" ;;
            -u)  echo "1001" ;;
            *)   echo "testuser" ;;
        esac
    }
    export -f id

    # Override getent so get_owner_home resolves to a deterministic, test-controlled home
    # directory regardless of which user is looked up (some tests pass "root" or the real
    # test-runner account as the unit user to exercise the ownership-heal ExecStartPre lines
    # — see ownership_heal_cmd_for/local_ownership_heal_cmd_for below).
    # shellcheck disable=SC2329
    getent() {
        printf '%s:x:1001:1001:Test User:%s:/bin/bash\n' "$1" "${TEST_TMP}/home"
    }
    export -f getent

    # shellcheck disable=SC2034 # read by the sourced lib/systemd-units
    UNIT_DIR="${TEST_TMP}/units"
    export UNIT_DIR

    source_systemd_units
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
# grouping with a \( -o \) (see lib/systemd-units) so this line never depends on how systemd's own
# Exec line parser handles an escape sequence it doesn't recognise.
assert_ownership_heal_execstartpre() {
    local svc="$1"
    grep -qE 'ExecStartPre=\+-/bin/sh -c .\[ -z "\$\(/usr/bin/find ".*" -not -user .* -print -quit -o -not -group .* -print -quit 2>/dev/null\)" \] \|\| /usr/bin/chown -R .*:.* ".*".$' "${svc}"
}

# Asserts the ownership-heal step (#1300/#1302) runs before the self-update fetch step, so a
# healed checkout is guaranteed to be in place before the merge that depends on it; a reorder
# would keep both assert_* greps above green while silently disabling the fix. Matching either
# marker and checking which one it is works because they're each unique to their own line: the
# first line in the file matching either pattern must be the heal line for this to pass.
assert_ownership_heal_before_selfupdate() {
    local svc="$1"
    grep -m1 -E 'ExecStartPre=\+-/bin/sh -c|ExecStartPre=-/usr/bin/timeout 60' "${svc}" | grep -q '+-/bin/sh -c'
}

# Asserts the /home/<owner>/.local ownership-heal ExecStartPre line (#1232): mkdir -p (handles a
# missing directory the same way a drifted-owner one is handled) then detect-then-chown using an
# absolute, -maxdepth 0 find (a single stat, not a walk of the whole tree - .local/share/containers
# can be many GB) and absolute /usr/bin/chown, mirroring setup-owner's own pattern. Prefixed
# '-+' rather than the REPO_DIR heal's '+-': functionally identical (systemd Exec-line prefix
# order is insignificant) but textually distinct, so a marker/grep keyed on the exact prefix
# string can never conflate the two lines - see assert_ownership_heal_execstartpre above for the
# REPO_DIR line this must not be confused with.
assert_local_ownership_heal_execstartpre() {
    local svc="$1"
    grep -qE 'ExecStartPre=-\+/bin/sh -c ./usr/bin/mkdir -p ".*\.local" && \{ \[ -z "\$\(/usr/bin/find ".*\.local" -maxdepth 0 -not -user .* -print -quit -o -maxdepth 0 -not -group .* -print -quit 2>/dev/null\)" \] \|\| /usr/bin/chown -R .*:.* ".*\.local"; \}.$' "${svc}"
}

# Asserts the .local heal (#1232) is the very first ExecStartPre in the unit, ahead of even the
# REPO_DIR heal (#1300/#1302) and self-update steps: the plan requires this ordering so a
# recurrence self-heals before anything else in the unit - including oneshot's own podman
# invocation - can fail because of it.
assert_local_ownership_heal_is_first_execstartpre() {
    local svc="$1"
    grep -m1 -E '^ExecStartPre=' "${svc}" | grep -qF -- '-+/bin/sh -c'
}

# Extracts a single-quoted /bin/sh -c '...' command embedded in a generated unit file, given a
# grep marker unique to the target ExecStartPre line. Shared by selfupdate_retry_cmd_for and
# ownership_heal_cmd_for below, which differ only in how they configure the unit before
# generating it and which line's marker they pass in. Returns non-zero on a broken extraction
# (e.g. the grep stops matching after a lib/systemd-units change) rather than printing an empty
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

# Regenerates the systemd service unit for user running from repo_dir, then extracts the
# ExecStartPre command matching marker. Shared by selfupdate_retry_cmd_for and
# ownership_heal_cmd_for below, which differ only in which user/repo_dir they pass and which
# line's marker they pass in.
generated_execstartpre_cmd() {
    local marker="$1" user="$2" repo_dir="$3"
    local service_name="credfeto-orchestrator-testuser"
    create_service_unit "${user}" "${service_name}" "${repo_dir}" >/dev/null || return 1
    local svc="${TEST_TMP}/units/${service_name}.service"
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
# `run /bin/sh -c "$(...)"`. Shared by the two regression tests below. repo_dir is passed straight
# to create_service_unit, so the extracted line already targets it directly, no
# text-surgery/retargeting needed.
selfupdate_retry_cmd_for() {
    local repo_dir="$1"
    # "timeout 30 /bin/sh -c '" is unique to the merge-retry line — the unrelated gpg-agent socket
    # step a few lines below also matches a bare "/bin/sh -c '".
    generated_execstartpre_cmd "timeout 30 /bin/sh -c '" "testuser" "${repo_dir}"
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
# ready for `run /bin/sh -c "$(...)"`. current_user is passed as the unit user rather than the
# unresolvable "testuser", so the extracted command's `find -user`/`-group` arguments name a
# real, resolvable account, since a nonexistent username makes find itself error out rather than
# exercise the detect logic.
ownership_heal_cmd_for() {
    local repo_dir="$1" current_user="$2"
    generated_execstartpre_cmd "ExecStartPre=+-/bin/sh -c '" "${current_user}" "${repo_dir}"
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
    # this test, so the extracted find/chown command's unit user matches the temp repo's
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
    # naming "root" as the unit user reproduces real drift (analogous to #1300's root-run
    # diagnostic command reowning .git/index) without needing privilege to actually chown a file
    # away from its real owner. The chown this triggers then genuinely fails with "Operation not
    # permitted": this test is run unprivileged deliberately, so it proves the detect-then-chown
    # branch was taken (the exact command the '+' prefix lets systemd run as root in production)
    # without asserting on privileged behaviour this suite cannot grant itself. If the suite itself
    # is somehow run as root (e.g. a container-based CI runner), naming "root" as the unit user
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

# Extracts the .local ownership-heal ExecStartPre command for owner_home_dir/current_user as a
# plain string, ready for `run /bin/sh -c "$(...)"`. Unlike repo_dir (passed straight to
# create_service_unit), owner_home is resolved inside create_service_unit via
# get_owner_home/getent, so this also redefines getent itself to return owner_home_dir regardless
# of current_user, bypassing the file-level getent stub.
local_ownership_heal_cmd_for() {
    local owner_home_dir="$1" current_user="$2"
    # shellcheck disable=SC2329
    getent() { printf '%s:x:1001:1001:Test User:%s:/bin/bash\n' "$1" "${owner_home_dir}"; }
    export -f getent
    generated_execstartpre_cmd "ExecStartPre=-+/bin/sh -c '" "${current_user}" "${REPO_ROOT}"
}

@test "the .local ownership-heal ExecStartPre is a no-op when nothing is owned by a different user (#1232, real repro)" {
    # command bypasses the file-level `id` shell-function stub to get the real account running
    # this test, so the extracted find/chown command's unit user matches the temp home's actual
    # on-disk owner and genuinely exercises the no-drift path, not a forced pass.
    local real_user
    real_user=$(command id -un)

    local home="${TEST_TMP}/local-heal-no-drift-home"
    mkdir -p "${home}/.local"

    run_execstartpre_cmd "$(local_ownership_heal_cmd_for "${home}" "${real_user}")"
    [ "${status}" -eq 0 ]
}

@test "the .local ownership-heal ExecStartPre creates .local when it does not exist yet (#1232)" {
    local real_user
    real_user=$(command id -un)

    local home="${TEST_TMP}/local-heal-missing-home"
    mkdir -p "${home}"
    [ ! -e "${home}/.local" ]

    run_execstartpre_cmd "$(local_ownership_heal_cmd_for "${home}" "${real_user}")"
    [ "${status}" -eq 0 ]
    [ -d "${home}/.local" ]
}

@test "the .local ownership-heal ExecStartPre detects drift and attempts to reassert ownership (#1232, real repro)" {
    # Every file under .local is genuinely owned by the account running this test, not by root, so
    # naming "root" as the unit user reproduces real drift (analogous to the #1232 incident) without
    # needing privilege to actually chown a directory away from its real owner. The chown this
    # triggers then genuinely fails with "Operation not permitted": this test is run unprivileged
    # deliberately, so it proves the detect-then-chown branch was taken (the exact command the
    # '-+' prefix lets systemd run as root in production) without asserting on privileged
    # behaviour this suite cannot grant itself. If the suite itself is somehow run as root (e.g. a
    # container-based CI runner), naming "root" as the unit user would never look like drift and
    # the chown would genuinely succeed, so skip rather than fail.
    if [ "$(command id -u)" -eq 0 ]; then
        skip "requires an unprivileged test runner to reproduce ownership drift"
    fi

    local home="${TEST_TMP}/local-heal-drift-home"
    mkdir -p "${home}/.local"

    LC_ALL=C run_execstartpre_cmd "$(local_ownership_heal_cmd_for "${home}" "root")"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Operation not permitted"* ]]

    # The failed, unprivileged chown must not have silently succeeded in any partial form: the
    # home's actual owner (this test's own account) must be unchanged.
    run find "${home}/.local" -not -user "$(command id -un)" -print -quit
    [ -z "${output}" ]
}

@test "install_systemd_units creates unit files and invokes systemctl correctly" {
    run install_systemd_units testuser "${REPO_ROOT}"
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
    assert_local_ownership_heal_execstartpre "${svc}"
    assert_local_ownership_heal_is_first_execstartpre "${svc}"
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

    [ -f "${TEST_TMP}/systemctl.log" ]
    grep -q "systemctl daemon-reload" "${TEST_TMP}/systemctl.log"
    grep -q "systemctl enable credfeto-orchestrator-testuser.timer" "${TEST_TMP}/systemctl.log"
    grep -q "systemctl start credfeto-orchestrator-testuser.timer" "${TEST_TMP}/systemctl.log"
}

@test "install_systemd_units service unit includes security hardening directives" {
    run install_systemd_units testuser "${REPO_ROOT}"
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

@test "install_systemd_units service unit wires up OnFailure (#1361)" {
    run install_systemd_units testuser "${REPO_ROOT}"
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    [ -f "${svc}" ]
    # OnFailure points at a SEPARATE unit so alerting survives oneshot being too broken to
    # report on itself — the whole reason the 19.5h outage went unnoticed.
    grep -q "OnFailure=credfeto-orchestrator-testuser-failure.service" "${svc}"
}

@test "install_systemd_units does NOT set systemd start rate limiting (#1361)" {
    run install_systemd_units testuser "${REPO_ROOT}"
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    [ -f "${svc}" ]
    # StartLimitIntervalSec/StartLimitBurst rate-limit ALL starts, not just failed ones, so any
    # burst small enough to catch a wedged service also throttles a healthy one against the 30s
    # timer — and a rate-limited unit self-clears anyway, so it never delivers the "stop until a
    # human looks" behaviour it appears to promise. Asserted absent so it cannot be reintroduced
    # without revisiting that reasoning.
    [ "$(grep -c '^StartLimitIntervalSec=' "${svc}")" -eq 0 ]
    [ "$(grep -c '^StartLimitBurst=' "${svc}")" -eq 0 ]
}

@test "install_systemd_units service unit removes the agent container on stop (#1361)" {
    run install_systemd_units testuser "${REPO_ROOT}"
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    [ -f "${svc}" ]
    # No --owner: OWNER varies per repo within a run, so no single literal name is correct and
    # the teardown has to sweep by prefix instead.
    grep -qF 'ExecStop=-/bin/sh -c ' "${svc}"
    grep -qF 'podman ps -aq --filter name=^orchestrator-' "${svc}"
    grep -q "TimeoutStopSec=90" "${svc}"
    # KillMode must stay at the default (control-group): it SIGTERMs the whole cgroup so podman
    # can tear the container down. KillMode=mixed would SIGTERM only the main process and SIGKILL
    # podman after the timeout — re-creating the mid-teardown kill that caused #1361.
    [ "$(grep -c '^KillMode=' "${svc}")" -eq 0 ]
}

@test "install_systemd_units --owner ExecStop targets the OWNER container name, not the unix user (#1361)" {
    run install_systemd_units testuser "${REPO_ROOT}" myorg
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser-myorg.service"
    [ -f "${svc}" ]
    # lib/podman names the container orchestrator-${OWNER} (the GitHub owner), NOT the host unix
    # user. They coincide only when setup-owner's naming convention is followed; using
    # the unit user here would remove the wrong name and silently fail to prevent the orphan.
    grep -q "ExecStop=-/usr/bin/podman rm -f orchestrator-myorg" "${svc}"
    [ "$(grep -c 'rm -f orchestrator-testuser' "${svc}")" -eq 0 ]
}

@test "install_systemd_units creates the failure-notifier unit (#1361)" {
    run install_systemd_units testuser "${REPO_ROOT}"
    [ "${status}" -eq 0 ]

    local failure_unit="${TEST_TMP}/units/credfeto-orchestrator-testuser-failure.service"
    [ -f "${failure_unit}" ]
    grep -q "User=testuser" "${failure_unit}"
    grep -qE "ExecStart=.*/notify-unit-failure credfeto-orchestrator-testuser\.service$" "${failure_unit}"
    # Must not chain OnFailure= onto itself: nothing to escalate to, and it would loop.
    [ "$(grep -c '^OnFailure=' "${failure_unit}")" -eq 0 ]
}

@test "install_systemd_units --owner scopes the failure-notifier unit to the owner (#1361)" {
    run install_systemd_units testuser "${REPO_ROOT}" myorg
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser-myorg.service"
    local failure_unit="${TEST_TMP}/units/credfeto-orchestrator-testuser-myorg-failure.service"
    [ -f "${failure_unit}" ]
    grep -q "OnFailure=credfeto-orchestrator-testuser-myorg-failure.service" "${svc}"
    grep -qE "ExecStart=.*/notify-unit-failure credfeto-orchestrator-testuser-myorg\.service$" "${failure_unit}"
}

@test "install_systemd_units respects stop-timeout and notifier-timeout overrides (#1361)" {
    # shellcheck disable=SC2030,SC2031,SC2034  # read by create_service_unit in the sourced lib/systemd-units
    ORCHESTRATOR_TIMEOUT_STOP_SEC=42
    # shellcheck disable=SC2030,SC2031,SC2034  # read by create_failure_unit in the sourced lib/systemd-units
    ORCHESTRATOR_NOTIFY_TIMEOUT_START_SEC=7
    run install_systemd_units testuser "${REPO_ROOT}"
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    local failure_unit="${TEST_TMP}/units/credfeto-orchestrator-testuser-failure.service"
    [ -f "${svc}" ]
    grep -q "TimeoutStopSec=42" "${svc}"
    grep -q "TimeoutStartSec=7" "${failure_unit}"
}

@test "install_systemd_units failure unit is bounded and hardened (#1361)" {
    run install_systemd_units testuser "${REPO_ROOT}"
    [ "${status}" -eq 0 ]

    local failure_unit="${TEST_TMP}/units/credfeto-orchestrator-testuser-failure.service"
    [ -f "${failure_unit}" ]
    # Unbounded, a blackholed webhook host would leave this 'activating' forever and later
    # OnFailure activations would coalesce into it, silently disabling alerting (#1098's shape).
    grep -q "TimeoutStartSec=60" "${failure_unit}"
    # This unit only runs grep/journalctl/jq/curl, so unlike the main unit it can take the strict
    # settings the main unit must not (rootless podman needs CAP_SETUID/CAP_SETGID there).
    grep -q "NoNewPrivileges=yes" "${failure_unit}"
    grep -q "ProtectSystem=strict" "${failure_unit}"
    grep -qE "^CapabilityBoundingSet=$" "${failure_unit}"
}

@test "install_systemd_units respects ORCHESTRATOR_TIMEOUT_START_SEC override (#1098)" {
    # shellcheck disable=SC2030,SC2031,SC2034  # read by create_service_unit in the sourced lib/systemd-units
    ORCHESTRATOR_TIMEOUT_START_SEC=1234
    run install_systemd_units testuser "${REPO_ROOT}"
    [ "${status}" -eq 0 ]

    local svc="${TEST_TMP}/units/credfeto-orchestrator-testuser.service"
    [ -f "${svc}" ]
    grep -q "TimeoutStartSec=1234" "${svc}"
}

@test "install_systemd_units --owner creates owner-scoped unit files with --owner in ExecStart" {
    run install_systemd_units testuser "${REPO_ROOT}" myorg
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
    assert_local_ownership_heal_execstartpre "${svc}"
    assert_local_ownership_heal_is_first_execstartpre "${svc}"
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

    [ -f "${TEST_TMP}/systemctl.log" ]
    grep -q "systemctl enable credfeto-orchestrator-testuser-myorg.timer" "${TEST_TMP}/systemctl.log"
    grep -q "systemctl start credfeto-orchestrator-testuser-myorg.timer" "${TEST_TMP}/systemctl.log"
}

@test "systemd_service_name prints the per-user unit name" {
    run systemd_service_name testuser
    [ "${status}" -eq 0 ]
    [ "${output}" = "credfeto-orchestrator-testuser" ]
}

@test "systemd_service_name appends the owner filter" {
    run systemd_service_name testuser myorg
    [ "${status}" -eq 0 ]
    [ "${output}" = "credfeto-orchestrator-testuser-myorg" ]
}

@test "install_systemd_units with an empty user dies without writing units" {
    run install_systemd_units "" "${REPO_ROOT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"user must not be empty"* ]]
    [ -z "$(ls -A "${TEST_TMP}/units")" ]
    [ ! -f "${TEST_TMP}/systemctl.log" ]
}

@test "install_systemd_units with an invalid owner filter dies without writing units" {
    run install_systemd_units testuser "${REPO_ROOT}" "evil;cmd"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"owner contains invalid characters"* ]]
    [ -z "$(ls -A "${TEST_TMP}/units")" ]
    [ ! -f "${TEST_TMP}/systemctl.log" ]
}

@test "install_systemd_units with an empty repo dir dies without invoking systemctl" {
    run install_systemd_units testuser ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Repository directory must not be empty"* ]]
    [ ! -f "${TEST_TMP}/systemctl.log" ]
}

@test "lib/systemd-units does not invoke sudo" {
    run bash -c "grep -v '^[[:space:]]*#' '${REPO_ROOT}/lib/systemd-units' | grep -n 'sudo'"
    [ "${status}" -ne 0 ]
}
