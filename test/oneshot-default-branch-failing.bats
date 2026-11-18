#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# A PR whose every failing required check also fails on its base branch is parked: no session, no
# budget charged, one status comment (#1975).

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# PR #5 in org/repo, based on main, with the given statusCheckRollup.
_dbf_pr_json() {
    printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"depends/x","baseRefName":"main","comments":[],"reviews":[],"statusCheckRollup":%s,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' "$1"
}

_DBF_BUILD_FAILS='[{"name":"build","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-11-18T10:00:00Z"},{"name":"lint","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"startedAt":"2026-11-18T10:00:00Z"}]'
_DBF_BUILD_AND_LINT_FAIL='[{"name":"build","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-11-18T10:00:00Z"},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-11-18T10:00:00Z"}]'

# main mocks for PR #5 in org/repo, changed since last tick (so it would otherwise get a session),
# with gh logged to GH_CALL_LOG and the base branch's verdicts read from DBF_VERDICTS_FILE, each
# lookup counted in DBF_LOOKUP_LOG.
_dbf_setup_main() {
    local rollup="$1"
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    DBF_ROLLUP="${rollup}"
    fetch_pr_json() { _dbf_pr_json "${DBF_ROLLUP}"; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint() { printf 'fp-old\n'; }
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    DBF_VERDICTS_FILE="${TEST_TMP}/verdicts"
    DBF_LOOKUP_LOG="${TEST_TMP}/lookups"
    fetch_branch_check_verdicts() {
        printf '%s %s\n' "$1" "$2" >> "${DBF_LOOKUP_LOG}"
        cat "${DBF_VERDICTS_FILE}"
    }
    invoke_claude() {
        printf 'called\n' >> "${TEST_TMP}/claude_log"
        printf '12345678-1234-1234-1234-123456789abc\n'
    }
}

_dbf_verdicts() {
    printf '%s\n' "$@" > "${DBF_VERDICTS_FILE}"
}

# --- pr_json_failed_required_check_names --------------------------------------

@test "pr_json_failed_required_check_names prints each failed required check once, sorted (#1975)" {
    run pr_json_failed_required_check_names '{"statusCheckRollup":[{"name":"zeta","status":"COMPLETED","conclusion":"FAILURE","isRequired":true},{"name":"zeta","workflowName":"other","status":"COMPLETED","conclusion":"TIMED_OUT","isRequired":true},{"context":"alpha","state":"ERROR","isRequired":true},{"name":"ok","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -eq 0 ]
    [ "${output}" = $'alpha\nzeta' ]
}

@test "pr_json_failed_required_check_names leaves out optional checks, checks of unknown required-ness and superseded failures (#1975)" {
    run pr_json_failed_required_check_names '{"statusCheckRollup":[{"name":"opt","status":"COMPLETED","conclusion":"FAILURE","isRequired":false},{"name":"unknown","status":"COMPLETED","conclusion":"FAILURE"},{"name":"build","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-11-18T09:00:00Z"},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"startedAt":"2026-11-18T10:00:00Z"}]}'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "pr_json_failed_required_check_names prints a control character in a name as a space, as cfwf does (#1975)" {
    run pr_json_failed_required_check_names '{"statusCheckRollup":[{"name":"build\tall","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 0 ]
    [ "${output}" = "build all" ]
}

# --- fetch_branch_check_verdicts ------------------------------------------------

@test "fetch_branch_check_verdicts prints name and verdict for each check cfwf pr checks --branch judges (#1975)" {
    make_stub_multiline cfwf \
        'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/cfwf_args"' \
        'printf "build\tfail\t2026-11-18T10:00:00Z\t1\nlint\tpending\t\t\nunit\tpass\t2026-11-18T10:00:00Z\t2\nsummary passed=1 failed=1 pending=1 head=abc\n"' \
        'exit 3'
    CFWF_SCRIPT="${STUB_BIN}/cfwf"
    run fetch_branch_check_verdicts org/repo main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'build\tfail\nlint\tpending\nunit\tpass' ]
    [ "$(cat "${TEST_TMP}/cfwf_args")" = "pr checks --repo org/repo --branch main" ]
}

@test "fetch_branch_check_verdicts accepts cfwf's pass and pending exit codes (#1975)" {
    local code
    for code in 0 4; do
        make_stub cfwf "printf 'build\tpass\t\t\nsummary passed=1 failed=0 pending=0 head=abc\n'; exit ${code}"
        CFWF_SCRIPT="${STUB_BIN}/cfwf"
        run fetch_branch_check_verdicts org/repo main
        [ "${status}" -eq 0 ]
        [ "${output}" = $'build\tpass' ]
    done
}

@test "fetch_branch_check_verdicts prints nothing when the branch tip has no checks at all (#1975)" {
    make_stub cfwf 'exit 5'
    CFWF_SCRIPT="${STUB_BIN}/cfwf"
    run fetch_branch_check_verdicts org/repo main
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "fetch_branch_check_verdicts fails when cfwf fails, prints an unexpected line, or is missing (#1975)" {
    make_stub cfwf 'echo "cfwf: could not read" >&2; exit 1'
    CFWF_SCRIPT="${STUB_BIN}/cfwf"
    run fetch_branch_check_verdicts org/repo main
    [ "${status}" -ne 0 ]

    make_stub cfwf "printf 'build\tbroken\t\t\nsummary passed=0 failed=0 pending=0 head=abc\n'; exit 0"
    run fetch_branch_check_verdicts org/repo main
    [ "${status}" -ne 0 ]

    CFWF_SCRIPT="${TEST_TMP}/no-such-cfwf"
    run fetch_branch_check_verdicts org/repo main
    [ "${status}" -ne 0 ]
}

# --- load_branch_completed_check_verdicts ---------------------------------------

@test "load_branch_completed_check_verdicts keeps a check's last completed verdict while it is pending and drops a check no longer reported (#1975)" {
    DEFAULT_BRANCH_CHECKS_CACHE_SECS=0
    printf '%s\n%s\n%s\n' "1" $'build\tfail' $'gone\tfail' > "$(branch_check_verdicts_cache_path main)"
    fetch_branch_check_verdicts() { printf 'build\tpending\nlint\tpending\nunit\tpass\n'; }
    run load_branch_completed_check_verdicts org/repo main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'build\tfail\nunit\tpass' ]
    [ "$(tail -n +2 "$(branch_check_verdicts_cache_path main)")" = $'build\tfail\nunit\tpass' ]
}

@test "load_branch_completed_check_verdicts reuses a fresh cache without a lookup, and looks up again once it is older than DEFAULT_BRANCH_CHECKS_CACHE_SECS (#1975)" {
    DEFAULT_BRANCH_CHECKS_CACHE_SECS=300
    fetch_branch_check_verdicts() {
        printf 'x\n' >> "${TEST_TMP}/lookups"
        printf 'build\tpass\n'
    }
    printf '%s\n%s\n' "$(date +%s)" $'build\tfail' > "$(branch_check_verdicts_cache_path main)"
    run load_branch_completed_check_verdicts org/repo main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'build\tfail' ]
    [ ! -f "${TEST_TMP}/lookups" ]

    printf '%s\n%s\n' "$(($(date +%s) - 301))" $'build\tfail' > "$(branch_check_verdicts_cache_path main)"
    run load_branch_completed_check_verdicts org/repo main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'build\tpass' ]
    [ "$(wc -l < "${TEST_TMP}/lookups")" -eq 1 ]
}

@test "load_branch_completed_check_verdicts keeps a cache file per branch, with a slash in the name encoded (#1975)" {
    run branch_check_verdicts_cache_path release/v2
    [ "${status}" -eq 0 ]
    [ "${output}" = "${SESSION_BASE_DIR}/branch-checks.release%2Fv2" ]
}

@test "load_branch_completed_check_verdicts fails, leaving the cache as it was, when the lookup fails (#1975)" {
    DEFAULT_BRANCH_CHECKS_CACHE_SECS=0
    printf '%s\n%s\n' "1" $'build\tfail' > "$(branch_check_verdicts_cache_path main)"
    fetch_branch_check_verdicts() { return 1; }
    run load_branch_completed_check_verdicts org/repo main
    [ "${status}" -ne 0 ]
    [ "$(cat "$(branch_check_verdicts_cache_path main)")" = $'1\nbuild\tfail' ]
}

# --- pr_failures_all_on_default_branch -------------------------------------------

@test "pr_failures_all_on_default_branch is true, printing the names, when every failing required check also fails on the base branch (#1975)" {
    load_branch_completed_check_verdicts() { [ "$2" = "main" ] && printf 'build\tfail\nlint\tfail\nunit\tpass\n'; }
    run pr_failures_all_on_default_branch "$(_dbf_pr_json "${_DBF_BUILD_AND_LINT_FAIL}")" org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "build, lint" ]
}

@test "pr_failures_all_on_default_branch is false when one failing check passes on the base branch or has no completed result there (#1975)" {
    load_branch_completed_check_verdicts() { printf 'build\tfail\nlint\tpass\n'; }
    run pr_failures_all_on_default_branch "$(_dbf_pr_json "${_DBF_BUILD_AND_LINT_FAIL}")" org/repo
    [ "${status}" -eq 1 ]

    load_branch_completed_check_verdicts() { printf 'build\tfail\n'; }
    run pr_failures_all_on_default_branch "$(_dbf_pr_json "${_DBF_BUILD_AND_LINT_FAIL}")" org/repo
    [ "${status}" -eq 1 ]
}

@test "pr_failures_all_on_default_branch is false, without a lookup, when no required check failed or a failing check's required-ness is unknown (#1975)" {
    load_branch_completed_check_verdicts() {
        printf 'x\n' >> "${TEST_TMP}/lookups"
        printf 'build\tfail\n'
    }
    run pr_failures_all_on_default_branch "$(_dbf_pr_json '[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]')" org/repo
    [ "${status}" -eq 1 ]
    run pr_failures_all_on_default_branch "$(_dbf_pr_json '[{"name":"build","status":"COMPLETED","conclusion":"FAILURE","isRequired":true},{"name":"other","status":"COMPLETED","conclusion":"FAILURE"}]')" org/repo
    [ "${status}" -eq 1 ]
    [ ! -f "${TEST_TMP}/lookups" ]
}

@test "pr_failures_all_on_default_branch returns 2 with a warning when the base branch's verdicts cannot be read (#1975)" {
    load_branch_completed_check_verdicts() { return 1; }
    run pr_failures_all_on_default_branch "$(_dbf_pr_json "${_DBF_BUILD_FAILS}")" org/repo
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Failed to read the check results of main in org/repo"* ]]
}

@test "skip_pr_for_default_branch_failures does not park a PR with an unaddressed trusted comment (#1975)" {
    pr_failures_all_on_default_branch() { printf 'build'; }
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_calls"; exit 0'
    run skip_pr_for_default_branch_failures 5 org/repo "$(_dbf_pr_json "${_DBF_BUILD_FAILS}")" true
    [ "${status}" -eq 1 ]
    [ ! -f "${TEST_TMP}/gh_calls" ]
}

@test "default_branch_failing_comment names the checks and the base branch and takes backticks out of names (#1975)" {
    run default_branch_failing_comment 'build, li`nt' main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'also fails in the latest completed run on `main`: `build`, `lint`.'* ]]
    [[ "${output}" == *'so the fix belongs on `main`'* ]]
}

# --- main() -------------------------------------------------------------------------

@test "main parks a PR whose only failing required checks also fail on the default branch: no session, one log line, budgets untouched (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_FAILS}"
    _dbf_verdicts $'build\tfail' $'lint\tpending'
    save_pr_invocation_counts 5 3 2

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ "$(grep -c 'default branch failing the same checks' <<< "${output}")" -eq 1 ]
    [[ "${output}" == *"PR #5 in org/repo: default branch failing the same checks (build on main) — skipping, not counted against any budget"* ]]
    [[ "${output}" == *"No actionable work items found"*"unchanged: 1"* ]]
    [ "$(cat "${DBF_LOOKUP_LOG}")" = "org/repo main" ]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
    [ "${PR_INVOCATION_IDLE}" -eq 2 ]
    [ "$(grep -c '^pr comment 5 --repo org/repo' "${GH_CALL_LOG}")" -eq 1 ]
    grep -q 'the fix belongs on `main`' "${GH_CALL_LOG}"
    [ -f "$(default_branch_failing_record_path 5)" ]
}

@test "main posts the default-branch status comment only once over several parked cycles (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_FAILS}"
    _dbf_verdicts $'build\tfail'

    run main
    [ "${status}" -eq 0 ]
    run main
    [ "${status}" -eq 0 ]
    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ "$(grep -c '^pr comment 5' "${GH_CALL_LOG}")" -eq 1 ]
    [ "$(grep -c 'default branch failing the same checks' <<< "${output}")" -eq 1 ]
    # The cached verdicts are shared: one lookup for all three cycles.
    [ "$(wc -l < "${DBF_LOOKUP_LOG}")" -eq 1 ]
}

@test "main retries the default-branch status comment on the next cycle when posting it fails (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_FAILS}"
    _dbf_verdicts $'build\tfail'
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 1'

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"failed to post the default-branch status comment — retrying next tick"* ]]
    [ ! -f "$(default_branch_failing_record_path 5)" ]

    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^pr comment 5' "${GH_CALL_LOG}")" -eq 2 ]
    [ -f "$(default_branch_failing_record_path 5)" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main works a PR with mixed failures as before: one failing check passes on the default branch (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_AND_LINT_FAIL}"
    _dbf_verdicts $'build\tfail' $'lint\tpass'

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" != *"default branch failing the same checks"* ]]
    if [ -f "${GH_CALL_LOG}" ]; then
        [ "$(grep -c '^pr comment 5' "${GH_CALL_LOG}")" -eq 0 ]
    fi
    [ ! -f "$(default_branch_failing_record_path 5)" ]
}

@test "main picks a parked PR up again once the default branch turns green for its failing checks (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_FAILS}"
    DEFAULT_BRANCH_CHECKS_CACHE_SECS=0
    _dbf_verdicts $'build\tfail'

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ -f "$(default_branch_failing_record_path 5)" ]

    _dbf_verdicts $'build\tpass'
    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: no longer parked for the default branch failing the same checks — working it again"* ]]
    [ ! -f "$(default_branch_failing_record_path 5)" ]

    # Parked again later: a new spell gets its own comment.
    rm -f "${TEST_TMP}/claude_log"
    _dbf_verdicts $'build\tfail'
    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ "$(grep -c '^pr comment 5' "${GH_CALL_LOG}")" -eq 2 ]
}

@test "main keeps a parked PR parked while the default branch's check is still running on a new commit (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_FAILS}"
    DEFAULT_BRANCH_CHECKS_CACHE_SECS=0
    _dbf_verdicts $'build\tfail'
    run main
    [ "${status}" -eq 0 ]

    _dbf_verdicts $'build\tpending'
    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"default branch failing the same checks (build on main)"* ]]
}

@test "main works the PR as before, with a warning, when the default branch's checks cannot be read (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_FAILS}"
    fetch_branch_check_verdicts() { return 1; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Failed to read the check results of main in org/repo"* ]]
}

@test "main lets a same-repository Issue start while the repository's only PR is parked (#1975)" {
    _dbf_setup_main "${_DBF_BUILD_FAILS}"
    _dbf_verdicts $'build\tfail'
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"default branch failing the same checks"* ]]
    [[ "${output}" != *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
}

@test "main parks a pivoted PR whose only failing required checks also fail on the default branch (#1975)" {
    setup_main_pivot_mocks
    fetch_pr_json() { _dbf_pr_json "${_DBF_BUILD_FAILS}"; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint() { printf 'fp-old\n'; }
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    fetch_branch_check_verdicts() { printf 'build\tfail\n'; }
    invoke_claude() {
        printf 'called\n' >> "${TEST_TMP}/claude_log"
        printf '12345678-1234-1234-1234-123456789abc\n'
    }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #99 in org/repo: default branch failing the same checks (build on main)"* ]]
    [ "$(grep -c '^pr comment 99' "${GH_CALL_LOG}")" -eq 1 ]
}
