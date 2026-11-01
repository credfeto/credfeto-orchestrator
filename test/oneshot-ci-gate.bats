#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- CI pending gate ---------------------------------------------------------

@test "pr_json_has_pending_ci_checks returns true when a required check has status IN_PROGRESS" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when a required check has status QUEUED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"QUEUED","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when one of many required checks is not COMPLETED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true},{"name":"lint","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when all checks are COMPLETED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when a non-required check is pending" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"badge","status":"IN_PROGRESS","conclusion":null,"isRequired":false}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when a pending check has no isRequired field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when statusCheckRollup is empty" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when statusCheckRollup is absent" {
    run pr_json_has_pending_ci_checks '{}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false for a completed legacy StatusContext with no status field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"SUCCESS"}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false for a failed legacy StatusContext with no status field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"FAILURE"}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns true for a legacy StatusContext with state PENDING" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"PENDING"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true for a legacy StatusContext with state EXPECTED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"EXPECTED"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when a failed required CheckRun is mixed with a completed legacy StatusContext" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"FAILURE","isRequired":true},{"name":"legacy","state":"SUCCESS"}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false for a CheckRun with a stale non-COMPLETED status but a terminal conclusion already set" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"no-merge-commits","status":"IN_PROGRESS","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when status is COMPLETED even if conclusion has not propagated yet" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":null,"isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

# `gh pr view --json statusCheckRollup` reports an unset conclusion as "" rather than null (#1483).
@test "pr_json_has_pending_ci_checks returns true when a required check is IN_PROGRESS with an empty-string conclusion" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":"","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when a required check is QUEUED with an empty-string conclusion" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"QUEUED","conclusion":"","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true for an IN_PROGRESS empty-string conclusion among completed checks with no isRequired field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"build-development-full","status":"IN_PROGRESS","conclusion":""}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when a non-required check is IN_PROGRESS with an empty-string conclusion" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"badge","status":"IN_PROGRESS","conclusion":"","isRequired":false}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when status is COMPLETED with an empty-string conclusion" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "clear_pr_ci_pending_state removes the state file when it exists" {
    save_pr_head_oid 42 "deadbeef" "1700000000"
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ -f "${state_file}" ]
    clear_pr_ci_pending_state 42
    [ ! -f "${state_file}" ]
}

@test "clear_pr_ci_pending_state succeeds silently when no state file exists" {
    run clear_pr_ci_pending_state 99
    [ "${status}" -eq 0 ]
}

@test "load_pr_head_oid returns empty string when no state file exists" {
    run load_pr_head_oid 42
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "save_pr_head_oid and load_pr_head_oid round-trip the OID and timestamp" {
    save_pr_head_oid 42 "deadbeef" "1700000000"
    run load_pr_head_oid 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "deadbeef 1700000000" ]
}

@test "load_pr_last_agent_comment_seen returns empty string when no state file exists (#1307)" {
    run load_pr_last_agent_comment_seen 42
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "save_pr_last_agent_comment_seen and load_pr_last_agent_comment_seen round-trip the timestamp (#1307)" {
    save_pr_last_agent_comment_seen 42 "2026-08-12T10:05:07Z"
    run load_pr_last_agent_comment_seen 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "fetch_pr_latest_trusted_comment_timestamp fetches fresh PR state rather than reusing stale data (#1307 review)" {
    fetch_pr_json() { printf '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[]}\n'; }
    get_trusted_logins() { printf '["credfeto"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    fetch_pr_issue_comments() { printf '[]\n'; }
    run fetch_pr_latest_trusted_comment_timestamp 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "fetch_pr_latest_trusted_comment_timestamp returns 1 when fetch_pr_json fails (#1307)" {
    fetch_pr_json() { return 1; }
    run fetch_pr_latest_trusted_comment_timestamp 42
    [ "${status}" -eq 1 ]
}

@test "fetch_pr_latest_trusted_comment_timestamp returns 1 when fetch_pr_review_comments fails (#1307 review)" {
    fetch_pr_json() { printf '{"comments":[]}\n'; }
    get_trusted_logins() { printf '["credfeto"]\n'; }
    fetch_pr_review_comments() { return 1; }
    run fetch_pr_latest_trusted_comment_timestamp 42
    [ "${status}" -eq 1 ]
}

@test "fetch_pr_latest_trusted_comment_timestamp returns 1 when fetch_pr_issue_comments fails (#1309)" {
    fetch_pr_json() { printf '{"comments":[]}\n'; }
    get_trusted_logins() { printf '["credfeto"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    fetch_pr_issue_comments() { return 1; }
    run fetch_pr_latest_trusted_comment_timestamp 42
    [ "${status}" -eq 1 ]
}

@test "fetch_pr_latest_trusted_comment_timestamp picks up an issue comment's updated_at via fetch_pr_issue_comments (#1309)" {
    fetch_pr_json() { printf '{"comments":[],"reviews":[]}\n'; }
    get_trusted_logins() { printf '["credfeto"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    fetch_pr_issue_comments() { printf '[{"user":{"login":"credfeto"},"created_at":"2026-08-12T07:26:12Z","updated_at":"2026-08-12T10:05:07Z"}]\n'; }
    run fetch_pr_latest_trusted_comment_timestamp 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_unknown_merge_state_timed_out starts the clock on the first UNKNOWN and returns false (#1701)" {
    run pr_unknown_merge_state_timed_out 42 "UNKNOWN"
    [ "${status}" -ne 0 ]
    [ -f "$(pr_unknown_merge_state_file_path 42)" ]
    [[ "$(cat "$(pr_unknown_merge_state_file_path 42)")" =~ ^[0-9]+$ ]]
}

@test "pr_unknown_merge_state_timed_out returns false while UNKNOWN is younger than the timeout (#1701)" {
    save_pr_unknown_merge_state_since 42 "$(($(date +%s) - 60))"
    UNKNOWN_MERGE_STATE_TIMEOUT_MINUTES=60
    run pr_unknown_merge_state_timed_out 42 "UNKNOWN"
    [ "${status}" -ne 0 ]
}

@test "pr_unknown_merge_state_timed_out returns true once UNKNOWN reaches the timeout and restarts the clock (#1701)" {
    local old
    old=$(($(date +%s) - 7200))
    save_pr_unknown_merge_state_since 42 "${old}"
    UNKNOWN_MERGE_STATE_TIMEOUT_MINUTES=60
    run pr_unknown_merge_state_timed_out 42 "UNKNOWN"
    [ "${status}" -eq 0 ]
    local saved
    saved=$(cat "$(pr_unknown_merge_state_file_path 42)")
    [ "${saved}" -gt "${old}" ]
    run pr_unknown_merge_state_timed_out 42 "UNKNOWN"
    [ "${status}" -ne 0 ]
}

@test "pr_unknown_merge_state_timed_out clears the clock for any other merge state (#1701)" {
    save_pr_unknown_merge_state_since 42 "$(($(date +%s) - 7200))"
    run pr_unknown_merge_state_timed_out 42 "CLEAN"
    [ "${status}" -ne 0 ]
    [ ! -f "$(pr_unknown_merge_state_file_path 42)" ]
}

@test "pr_unknown_merge_state_timed_out restarts the clock when the state file is unreadable (#1701)" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'garbage\n' > "$(pr_unknown_merge_state_file_path 42)"
    run pr_unknown_merge_state_timed_out 42 "UNKNOWN"
    [ "${status}" -ne 0 ]
    [[ "$(cat "$(pr_unknown_merge_state_file_path 42)")" =~ ^[0-9]+$ ]]
}

@test "pr_branch_behind_base reads behind_by from the compare API for the encoded branches (#1701)" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_args"
cat "'"${TEST_TMP}"'/behind"'
    local pr='{"baseRefName":"main","headRefName":"depends/update/1.2","isCrossRepository":false}'
    printf '267\n' > "${TEST_TMP}/behind"
    run pr_branch_behind_base "org/repo" "${pr}"
    [ "${status}" -eq 0 ]
    grep -qF 'api repos/org/repo/compare/main...depends%2Fupdate%2F1.2 --jq .behind_by' "${TEST_TMP}/gh_args"
    printf '0\n' > "${TEST_TMP}/behind"
    run pr_branch_behind_base "org/repo" "${pr}"
    [ "${status}" -eq 1 ]
    printf 'oops\n' > "${TEST_TMP}/behind"
    run pr_branch_behind_base "org/repo" "${pr}"
    [ "${status}" -eq 2 ]
}

@test "pr_branch_behind_base returns 2 when gh fails and 1 for a fork PR without calling gh (#1701)" {
    make_stub gh 'printf "called\n" >> "'"${TEST_TMP}"'/gh_called"; exit 1'
    run pr_branch_behind_base "org/repo" '{"baseRefName":"main","headRefName":"feat/x","isCrossRepository":false}'
    [ "${status}" -eq 2 ]
    rm -f "${TEST_TMP}/gh_called"
    run pr_branch_behind_base "org/repo" '{"baseRefName":"main","headRefName":"feat/x","isCrossRepository":true}'
    [ "${status}" -eq 1 ]
    [ ! -f "${TEST_TMP}/gh_called" ]
    run pr_branch_behind_base "org/repo" '{"headRefName":"feat/x"}'
    [ "${status}" -eq 1 ]
}

@test "pr_merge_state_stuck_behind needs both a timed-out UNKNOWN and a branch behind its base (#1701)" {
    pr_branch_behind_base() { return 0; }
    run pr_merge_state_stuck_behind 42 "org/repo" '{}' "UNKNOWN"
    [ "${status}" -ne 0 ]
    save_pr_unknown_merge_state_since 42 "$(($(date +%s) - 7200))"
    run pr_merge_state_stuck_behind 42 "org/repo" '{}' "UNKNOWN"
    [ "${status}" -eq 0 ]
    save_pr_unknown_merge_state_since 42 "$(($(date +%s) - 7200))"
    pr_branch_behind_base() { return 1; }
    run pr_merge_state_stuck_behind 42 "org/repo" '{}' "UNKNOWN"
    [ "${status}" -ne 0 ]
    save_pr_unknown_merge_state_since 42 "$(($(date +%s) - 7200))"
    pr_branch_behind_base() { return 2; }
    run pr_merge_state_stuck_behind 42 "org/repo" '{}' "UNKNOWN"
    [ "${status}" -ne 0 ]
    run pr_merge_state_stuck_behind 42 "org/repo" '{}' "CLEAN"
    [ "${status}" -ne 0 ]
}

@test "ci_checks_timed_out returns false and writes state on first call for a new OID" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ -f "${state_file}" ]
    [[ "$(cat "${state_file}")" == "abc123 "* ]]
}

@test "ci_checks_timed_out returns false when elapsed time is below CI_CHECK_TIMEOUT_MINUTES" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local now
    now=$(date +%s)
    save_pr_head_oid 42 "abc123" "${now}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
}

@test "ci_checks_timed_out returns true when elapsed time exceeds CI_CHECK_TIMEOUT_MINUTES" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 42 "abc123" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -eq 0 ]
}

@test "ci_checks_timed_out resets the clock and returns false when the OID changes" {
    local pr_json='{"headRefOid":"new-oid","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 42 "old-oid" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [[ "$(cat "${state_file}")" == "new-oid "* ]]
}

@test "ci_checks_timed_out returns false and writes no state when headRefOid is absent" {
    local pr_json='{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ ! -f "${state_file}" ]
}

@test "ci_checks_timed_out returns false and resets state when state file has no space (corrupted)" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'abc123' > "${state_file}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    [[ "$(cat "${state_file}")" == "abc123 "* ]]
}

@test "main defers agent invocation when PR has pending CI checks within timeout" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}

@test "main blocks PR and posts complaint when CI checks exceed timeout" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main skips (does not die on) a transient fetch_pr_json failure in the direct-PR path (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { return 1; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Failed to fetch state for PR #5 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main invokes agent when PR CI checks are all COMPLETED" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
}

@test "main skips (does not die on, and does not hand off to agent for) a get_trusted_logins failure in the direct-PR path (#1094)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    get_trusted_logins() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch trusted collaborators for org/repo"* ]]
}

@test "main skips (does not die on, and does not hand off to agent for) a fetch_pr_review_comments failure in the direct-PR path (#1127)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fetch_pr_review_comments() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch review comments for PR #5 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on, and does not hand off to agent for) a fetch_pr_review_comments failure in the Issue-to-PR pivot path (#1127)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fetch_pr_review_comments()  { return 1; }
    fingerprint_pr_json()       { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude()             { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch review comments for PR #99 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on, and does not hand off to agent for) a fetch_pr_issue_comments failure in the direct-PR path (#1309)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fetch_pr_issue_comments() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch issue comments for PR #5 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on, and does not hand off to agent for) a fetch_pr_issue_comments failure in the Issue-to-PR pivot path (#1309)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fetch_pr_issue_comments()   { return 1; }
    fingerprint_pr_json()       { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude()             { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch issue comments for PR #99 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main blocks a PR and does not invoke claude when its invocation total is at the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
    [[ "${output}" == *"used ${MAX_PR_TOTAL_INVOCATIONS} agent invocations without converging"* ]]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "main posts the PR-runaway reason as the comment body and to Discord when at the runaway cap (#1140 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q "pr comment 5 --repo org/repo --body This PR has been worked ${MAX_PR_TOTAL_INVOCATIONS} times by the automation without reaching a mergeable state" "${GH_CALL_LOG}"
    grep -q "type=PullRequest id=5 reason=This PR has been worked ${MAX_PR_TOTAL_INVOCATIONS} times by the automation without reaching a mergeable state" "${_notif_log}"
}

@test "main includes the last session's diagnostic in the PR-runaway Blocked comment when one was recorded (#1448)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    save_last_diagnostic "PullRequest" "5" "- Bash: gh pr view 5"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q "Last session's diagnostic:" "${GH_CALL_LOG}"
    grep -q -- '- Bash: gh pr view 5' "${GH_CALL_LOG}"
}

@test "main still blocks and warns loudly when the runaway-blocked marker cannot be written (#1093 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    # Guard file already written above; now make the directory unwritable so the runaway-blocked
    # marker touch fails — the label/comment escalation (a gh call, unaffected by local fs
    # permissions) must still go through, and the failure must be surfaced via warn rather than
    # silently swallowed.
    chmod 555 "${SESSION_BASE_DIR}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    chmod 755 "${SESSION_BASE_DIR}"
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
    # The warning comes from mark_capped_block_for_forgiveness itself (lib/state), called by
    # apply_blocked_label_with_reason with item_repo, rather than a bespoke message oneshot used
    # to print after its own now-removed duplicate touch of the same marker.
    [[ "${output}" == *"Failed to write runaway-blocked marker for PullRequest #5 in org/repo"* ]]
}

@test "main resets a PR's invocation counter when observed un-blocked after hitting the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    # No Blocked label — a human has already cleared it — but the guard file still holds the
    # capped total, and the runaway-blocked marker from the prior blocking tick is still present,
    # exercising the reset-on-unblock path (#1093).
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked"
    # The marker is present, so reset_pr_invocation_counts_if_capped re-confirms with a live
    # check (#1310) before honouring the reset — stub it to agree the label is genuinely gone.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    # Reset to 0/0 then bumped once for this invocation — proof the stale cap did not re-block it.
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_5.invocations")" = "1 0" ]
}

@test "main does not reset or invoke the agent for a PR when a stale read-after-write lags behind an already-verified Blocked label (#1310)" {
    # Reproduces #1310: a runaway-blocked marker is present (a prior tick applied and verified
    # Blocked), but THIS tick's own already-fetched JSON is a stale read lagging behind that
    # verified write and shows no Blocked label. The live re-check must catch this and treat the
    # tick as still blocked — no reset, no agent invocation, no re-post of the runaway comment.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo is blocked — skipping (not counting as active work)"* ]]
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_5.invocations")" = "${MAX_PR_TOTAL_INVOCATIONS} 0" ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
    # No duplicate runaway-cap escalation comment was posted this tick — the item was routed to
    # the ordinary blocked-skip branch, not through the backstop a second time.
    run grep -q 'pr comment 5' "${GH_CALL_LOG}"
    [ "${status}" -ne 0 ]
}

@test "main writes the runaway-blocked marker when observing a PR blocked by a non-backstop rule while at the cap (#1115 regression)" {
    # Reproduces the #116 bug's first half: a PR already carries the Blocked label (applied by
    # something other than oneshot's own backstop, e.g. the code-review workflow's "3+ rounds"
    # rule — hence no pre-existing marker) while its invocation total already sits at the cap.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":116,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    save_pr_invocation_counts 116 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #116 in org/repo is blocked — skipping (not counting as active work)"* ]]
    [ -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]
    # The total is untouched by observing the block — only forgiven once a human clears the label.
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_116.invocations")" = "${MAX_PR_TOTAL_INVOCATIONS} 0" ]
}

@test "main resumes work on a capped PR across two ticks after a human clears a non-backstop Blocked label (#1115 regression)" {
    # End-to-end reproduction of #116: tick 1 observes the PR blocked by a non-backstop rule while
    # at the cap (writes the marker); a human then clears the label; tick 2 must reset the counter
    # and actually invoke the agent instead of instantly re-blocking with zero new activity.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":116,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    save_pr_invocation_counts 116 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]

    # Human clears the label — simulate the next tick observing it unblocked.
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    # The marker from tick 1 is still present, so tick 2's reset re-confirms live (#1310) before
    # honouring it — stub it to agree the label is genuinely gone now.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_116.invocations")" = "1 0" ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]
}

@test "main auto-clears Blocked on an environment-diagnosed PR once a newer agent image has been built (#1118)" {
    # Reproduces the funfair-server-code-analysis#463 case: the agent diagnosed a missing-tool
    # environment failure and blocked itself; the fix has since shipped (a new image was built);
    # oneshot must notice on its own, without a human clearing the label — no agent work happens
    # this tick, the PR is simply freed up for the next tick to pick up normally.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":463,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[{"body":"Missing pgrep in the container. <!-- orchestrator:env-block image-sha=abc1234 -->"}],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr edit 463 --repo org/repo --remove-label Blocked' "${GH_CALL_LOG}"
    grep -q 'pr comment 463' "${GH_CALL_LOG}"
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_463.env-unblocks")" = "1" ]
}

@test "main leaves an environment-diagnosed PR blocked when no newer agent image has been built (#1118)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":463,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[{"body":"Missing pgrep in the container. <!-- orchestrator:env-block image-sha=abc1234 -->"}],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=abc1234\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #463 in org/repo is blocked — skipping (not counting as active work)"* ]]
    [[ "$(cat "${GH_CALL_LOG}")" != *"remove-label Blocked"* ]]
}

@test "main stops auto-unblocking an environment-diagnosed PR once MAX_PR_ENV_AUTO_UNBLOCKS is reached (#1118)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":463,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[{"body":"Missing pgrep in the container. <!-- orchestrator:env-block image-sha=abc1234 -->"}],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    save_env_unblock_attempts 463 "${MAX_PR_ENV_AUTO_UNBLOCKS}"
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "$(cat "${GH_CALL_LOG}")" != *"remove-label Blocked"* ]]
    grep -q 'pr comment 463' "${GH_CALL_LOG}"
    [ -f "${SESSION_BASE_DIR}/PullRequest_463.env-unblock-cap-notified" ]
}

@test "main does not die and does not save when the post-run PR fingerprint compute fails (#1091)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    compute_pr_fingerprint() { return 1; }
    save_pr_fingerprint() { printf 'saved\n' >> "${TEST_TMP}/save_log"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/save_log" ]
    [[ "${output}" == *"Failed to compute post-run fingerprint"* ]]
    [[ "${output}" == *"will re-evaluate next tick"* ]]
}

@test "main saves neither fingerprint when the PR succeeds but the linked issue's compute fails (atomicity, #1091)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '5\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    compute_pr_fingerprint() { printf 'pr-fp-ok\n'; return 0; }
    compute_issue_fingerprint() { return 1; }
    save_pr_fingerprint() { printf 'saved-pr\n' >> "${TEST_TMP}/save_log"; }
    save_issue_fingerprint() { printf 'saved-issue\n' >> "${TEST_TMP}/save_log"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/save_log" ]
    [[ "${output}" == *"Failed to compute post-run fingerprint"* ]]
}

@test "main does not die and does not save when the post-run Issue fingerprint compute fails (#1091)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    compute_issue_fingerprint() { return 1; }
    save_issue_fingerprint() { printf 'saved\n' >> "${TEST_TMP}/save_log"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/save_log" ]
    [[ "${output}" == *"Failed to compute post-run fingerprint for Issue #10"* ]]
}

@test "main blocks an Issue and does not invoke claude when its invocation total is at the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'issue comment 10' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
    [[ "${output}" == *"used ${MAX_ISSUE_TOTAL_INVOCATIONS} agent invocations without converging"* ]]
    [ -f "${SESSION_BASE_DIR}/Issue_10.runaway-blocked" ]
}

@test "main posts the Issue-runaway reason as the comment body and to Discord when at the runaway cap (#1140 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q "issue comment 10 --repo org/repo --body This issue has been worked ${MAX_ISSUE_TOTAL_INVOCATIONS} times by the automation without producing a mergeable pull request" "${GH_CALL_LOG}"
    grep -q "type=Issue id=10 reason=This issue has been worked ${MAX_ISSUE_TOTAL_INVOCATIONS} times by the automation without producing a mergeable pull request" "${_notif_log}"
}

@test "main includes the last session's diagnostic in the Issue-runaway Blocked comment when one was recorded (#1448)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    save_last_diagnostic "Issue" "10" "- Bash: gh issue view 10"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q "Last session's diagnostic:" "${GH_CALL_LOG}"
    grep -q -- '- Bash: gh issue view 10' "${GH_CALL_LOG}"
}

@test "main invokes agent and increments the invocation counter for an Issue below the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ -f "${SESSION_BASE_DIR}/Issue_10.invocations" ]
    [ "$(cat "${SESSION_BASE_DIR}/Issue_10.invocations")" = "1 0" ]
}

@test "main resets an Issue's invocation counter when observed un-blocked after hitting the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    # No Blocked label — a human has already cleared it — but the guard file still holds the
    # capped total, and the runaway-blocked marker from the prior blocking tick is still present,
    # exercising the reset-on-unblock path (#1093).
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_10.runaway-blocked"
    # The marker is present, so reset_issue_invocation_counts_if_capped re-confirms with a live
    # check (#1310) before honouring the reset — stub it to agree the label is genuinely gone.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    # Reset to 0 then bumped once for this invocation — proof the stale cap did not re-block it.
    [ "$(cat "${SESSION_BASE_DIR}/Issue_10.invocations")" = "1 0" ]
}

@test "main does not reset or invoke the agent for an Issue when a stale read-after-write lags behind an already-verified Blocked label (#1310)" {
    # Issue-side counterpart of the PR stale-read regression above.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_10.runaway-blocked"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [ "$(cat "${SESSION_BASE_DIR}/Issue_10.invocations")" = "${MAX_ISSUE_TOTAL_INVOCATIONS} 0" ]
    [ -f "${SESSION_BASE_DIR}/Issue_10.runaway-blocked" ]
    run grep -q 'issue comment 10' "${GH_CALL_LOG}"
    [ "${status}" -ne 0 ]
}

@test "main skips (does not die on, and does not hand off to agent for) a transient repo-fetch failure (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    ensure_repo_current() { return 2; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" != *"handing off to agent"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main blocks unchanged PR when CI has been pending past timeout in direct-PR path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged PR with idle budget exhausted and a failed required check in direct-PR path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged PR with idle budget exhausted and an unaddressed review request in direct-PR path (#1083)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged PR with idle budget exhausted and no known blocking reason in direct-PR path (#1463)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main invokes the agent for an unchanged draft PR within the idle budget in direct-PR path (#1447)" {
    # A draft PR whose fingerprint hasn't changed must still be re-invoked while under the idle
    # cap, exactly like a non-draft PR — draft status alone must not change this.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 2 2
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo unchanged — re-invoking to advance the next workflow phase"* ]]
    [ -f "${TEST_TMP}/claude_log" ]
}

@test "main does not charge the idle budget when a required check is still pending after the session, in direct-PR path (#1463)" {
    # The pre-invocation CI-pending check (pr_json_has_pending_ci_checks, run against the
    # pre-session pr_json) can race a slower container startup: CI can still be genuinely
    # pending by the time the agent itself checks, several seconds to a minute later, so its
    # own PHASE B no-op still lands here as an "unchanged" idle-advance. A re-check against
    # freshly fetched PR state after the session must catch that and leave the idle counter
    # unchanged (confirmed live on PR #1473, whose own idle budget was exhausted by exactly
    # this race one minute before its CI run actually finished).
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    local _pr_json_call_file="${TEST_TMP}/_pr_json_calls"
    printf '0' > "${_pr_json_call_file}"
    fetch_pr_json() {
        local _count
        _count=$(cat "${_pr_json_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_pr_json_call_file}"
        if [ "${_count}" -eq 1 ]; then
            # Pre-invocation snapshot: nothing pending, so the tick proceeds to the
            # idle-advance path and the agent is invoked.
            printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'
        else
            # Post-invocation re-fetch: the required check is still IN_PROGRESS.
            printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'
        fi
    }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 2 2
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: still CI-pending after this session — not counting it against the idle budget"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 2 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main resets the idle budget when the board advances during the session, in direct-PR path (#1474)" {
    # A clean phase advance (e.g. "Simplify clean - advancing to code review") pushes no commit
    # and posts no comment the fingerprint necessarily picks up, so it is otherwise
    # indistinguishable from genuine idleness to pr_should_advance_unchanged. The board actually
    # moving during the session is real progress and must reset the idle counter to 0 (confirmed
    # live: PR #799 in funfair-server-common was falsely Blocked after only three such advances).
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    local _board_call_file="${TEST_TMP}/_board_calls"
    printf '0' > "${_board_call_file}"
    fetch_single_item_workflow_status() {
        local _count
        _count=$(cat "${_board_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_board_call_file}"
        [ "${_count}" -eq 1 ] && printf 'AI Review' || printf 'AI Security Review'
    }
    fetch_pr_latest_trusted_comment_timestamp() { printf ''; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 2 2
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: not charging this session against the idle budget (board moved from AI Review to AI Security Review)"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main resets the idle budget when a new trusted comment is posted during the session, in direct-PR path (#1474)" {
    # A reply-only PHASE C round ("Posted the reply, no commit") leaves the board status
    # unchanged but is still real progress. A new trusted comment appearing after the session
    # must reset the idle counter to 0 the same as a board move does — using the same
    # trusted-filtered pr_json_latest_trusted_comment_timestamp/fetch_pr_latest_trusted_comment_timestamp
    # machinery the codebase already relies on elsewhere, not a raw unfiltered comment count.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fetch_single_item_workflow_status() { printf 'Development'; }
    fetch_pr_latest_trusted_comment_timestamp() { printf '2026-09-19T12:00:00Z\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 2 2
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: not charging this session against the idle budget (a trusted comment arrived during the session and is left unaddressed for the next run)"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main still charges the idle budget when neither the board nor comments changed, in direct-PR path (#1474)" {
    # Regression guard: a session that made literally no progress (same board substatus, no new
    # trusted comment activity, CI not pending) must still charge the idle budget as before #1474.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fetch_single_item_workflow_status() { printf 'AI Review'; }
    fetch_pr_latest_trusted_comment_timestamp() { printf ''; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 2 2
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"no progress this session"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main blocks unchanged draft PR with idle budget exhausted and a failed required check in direct-PR path (#1447)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged draft PR with idle budget exhausted and no known blocking reason in direct-PR path (#1463)" {
    # Matches the non-draft case above: with no failed-check/review-request escalation reason, an
    # idle-exhausted draft PR now gets the no-progress escalation instead of being silently
    # skipped — the same treatment a non-draft PR gets in this exact case (#1463).
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main does not invoke the agent for a changed-fingerprint terminal PR (auto-merge armed, nothing failed/pending) (#1256)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
}

@test "main still performs non-agentic rebase for a BEHIND PR even with auto-merge armed (#1256 regression guard)" {
    # pr_json_is_terminal ignores mergeStateStatus entirely, so without the explicit BEHIND/DIRTY
    # guard on the new hoisted terminal check, a PR that's actually waiting on a rebase (not
    # genuinely settled) could be misclassified as "nothing to do".
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [[ "${output}" != *"settled"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main rebases an auto-merge-armed PR whose merge state has stayed UNKNOWN and is behind its base instead of calling it settled (#1701)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"depends/update","baseRefName":"main","comments":[],"reviews":[],"reviewDecision":"APPROVED","statusCheckRollup":[],"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json()  { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    pr_branch_behind_base() { return 0; }
    try_nonagentic_rebase() { printf 'rebased\n' >> "${TEST_TMP}/rebase_log"; return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    save_pr_unknown_merge_state_since 5 "$(($(date +%s) - 7200))"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"merge state UNKNOWN for at least"*"treating as BEHIND"* ]]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [[ "${output}" != *"settled"* ]]
    [ -f "${TEST_TMP}/rebase_log" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main still treats a briefly UNKNOWN auto-merge-armed PR as settled and starts the UNKNOWN clock (#1701)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"depends/update","baseRefName":"main","comments":[],"reviews":[],"reviewDecision":"APPROVED","statusCheckRollup":[],"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json()  { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    pr_branch_behind_base() { printf 'called\n' >> "${TEST_TMP}/compare_log"; return 0; }
    try_nonagentic_rebase() { printf 'rebased\n' >> "${TEST_TMP}/rebase_log"; return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"settled"* ]]
    [[ "${output}" != *"treating as BEHIND"* ]]
    [ ! -f "${TEST_TMP}/compare_log" ]
    [ ! -f "${TEST_TMP}/rebase_log" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ -f "$(pr_unknown_merge_state_file_path 5)" ]
}

@test "main invokes the agent for a terminal, fingerprint-unchanged PR with an unaddressed trusted comment (#1307)" {
    # Reproduces the live incident this bug was reported against (funfair-tech/funfair-treasury-
    # reporting#3622): a prior non-agentic rebase already folded a new trusted comment into the
    # saved general PR fingerprint, so it now reads as "unchanged" AND the PR looks terminal
    # (auto-merge armed, nothing failed/pending). Neither skip must win — the comment has never
    # actually been read by a real agent.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" != *"settled"* ]]
    # Routed through the idle-tracked "re-invoking to advance" path (not a blanket bypass), so
    # the idle counter and failed-check/unaddressed-review-request escalation stay in force once
    # genuinely exhausted (#1307 review) — "unchanged" legitimately appears in that log line.
    [[ "${output}" == *"unchanged — re-invoking to advance the next workflow phase"* ]]
}

@test "main invokes the agent for a BEHIND PR with an unaddressed trusted comment instead of a non-agentic rebase (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { printf 'rebase-attempted\n' >> "${TEST_TMP}/rebase_log"; return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/rebase_log" ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" != *"rebased non-agentically"* ]]
}

@test "main still performs a non-agentic rebase for a BEHIND PR whose trusted comment was already seen by a prior agent invocation (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    load_pr_last_agent_comment_seen() { printf '2026-08-12T07:26:12Z\n'; }
    try_nonagentic_rebase() { return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main does not record last-agent-comment-seen after a non-agentic rebase (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    save_pr_last_agent_comment_seen() { printf 'called\n' >> "${TEST_TMP}/comment_seen_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [ ! -f "${TEST_TMP}/comment_seen_log" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main does not record last-agent-comment-seen after a terminal settled skip (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_last_agent_comment_seen() { printf 'called\n' >> "${TEST_TMP}/comment_seen_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"settled"* ]]
    [ ! -f "${TEST_TMP}/comment_seen_log" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main records last-agent-comment-seen after a genuine agent invocation (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_last_agent_comment_seen() { printf 'called\n' >> "${TEST_TMP}/comment_seen_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ -f "${TEST_TMP}/comment_seen_log" ]
}

@test "main still escalates a terminal PR with a failed required check and an unaddressed comment once idle budget is exhausted (#1307 review)" {
    # Regression guard: an unaddressed trusted comment must not permanently exempt a PR from the
    # idle-exhausted escalation checks — it may force one extra look, but once the idle budget is
    # genuinely spent the failed-check escalation must still fire, not silently churn forever.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main still sends the Discord review-approval nudge for a terminal PR even with an unaddressed comment (#1307 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"REVIEW_REQUIRED"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    notify_discord_pr_needs_approval() { printf 'called\n' >> "${TEST_TMP}/approval_notify_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ -f "${TEST_TMP}/approval_notify_log" ]
}

@test "main blocks PR and posts complaint when CI checks exceed timeout in Issue-to-PR pivot path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 7 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 7' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main clears CI pending state file when direct-PR CI timeout fires" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main preserves CI pending state file when the timeout escalation's label cannot be verified (#1092)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    # Label was never confirmed present — the 24h timeout clock must NOT be re-armed, and the
    # explanatory comment must NOT be posted (both were the exact spam/lost-escalation bug).
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ -f "${state_file}" ]
    run grep -q 'pr comment 5' "${GH_CALL_LOG}"
    [ "${status}" -ne 0 ]
}

@test "main clears CI pending state file when Issue-to-PR CI timeout fires" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 7 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 7)
    [ ! -f "${state_file}" ]
}

@test "main clears CI pending state file when direct-PR CI completes and fingerprint is unchanged" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    # Auto-merge enabled makes the unchanged, CI-green PR terminal so it is skipped (CI pending
    # state is still cleared) rather than being re-invoked to advance a phase.
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 30 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main preserves CI pending state file when direct-PR is skipped while CI still pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ -f "${state_file}" ]
}

@test "main preserves CI pending state file when Issue-to-PR pivot skips due to both FPs unchanged while CI still pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    fingerprint_issue_json()   { printf 'fp-same-issue\n'; }
    load_issue_fingerprint()   { printf 'fp-same-issue\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 7)
    [ -f "${state_file}" ]
}

@test "main clears CI pending state file when work-block CI timeout fires (fingerprint changed)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'Blocked' "${GH_CALL_LOG}"
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main defers unchanged BEHIND PR without invoking agent while CI is pending (direct-PR path)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}

@test "main defers unchanged draft PR in Issue-to-PR path without invoking agent while CI is pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}
