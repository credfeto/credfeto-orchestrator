#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- what counts as progress in a session with no external change ----------------------------------

@test "pr_session_progress_reason reports a board move" {
    run pr_session_progress_reason "AI Review" "AI Security Review" "" "" "abc" "abc"
    [ "${status}" -eq 0 ]
    [ "${output}" = "board moved from AI Review to AI Security Review" ]
}

@test "pr_session_progress_reason treats an Unknown board read on either side as inconclusive" {
    run pr_session_progress_reason "Unknown" "AI Review" "" "" "abc" "abc"
    [ "${status}" -eq 1 ]
    run pr_session_progress_reason "AI Review" "Unknown" "" "" "abc" "abc"
    [ "${status}" -eq 1 ]
}

@test "pr_session_progress_reason reports a trusted comment that arrived during the session, not as agent progress" {
    run pr_session_progress_reason "AI Review" "AI Review" "2026-10-01T10:00:00Z" "2026-10-01T11:00:00Z" "abc" "abc"
    [ "${status}" -eq 0 ]
    [ "${output}" = "a trusted comment arrived during the session and is left unaddressed for the next run" ]
}

@test "pr_session_progress_reason does not treat a deleted newest comment as one arriving (#1557)" {
    run pr_session_progress_reason "AI Review" "AI Review" "2026-10-01T11:00:00Z" "2026-10-01T10:00:00Z" "abc" "abc"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "pr_session_progress_reason counts a trusted comment when there was none before the session" {
    run pr_session_progress_reason "AI Review" "AI Review" "" "2026-10-01T10:00:00Z" "abc" "abc"
    [ "${status}" -eq 0 ]
    [ "${output}" = "a trusted comment arrived during the session and is left unaddressed for the next run" ]
}

@test "pr_session_progress_reason reports a pushed commit" {
    run pr_session_progress_reason "AI Review" "AI Review" "" "" "abc" "def"
    [ "${status}" -eq 0 ]
    [ "${output}" = "a commit was pushed" ]
}

@test "pr_session_progress_reason finds no progress when nothing moved or the post reads failed" {
    run pr_session_progress_reason "AI Review" "AI Review" "2026-10-01T10:00:00Z" "2026-10-01T10:00:00Z" "abc" "abc"
    [ "${status}" -eq 1 ]
    run pr_session_progress_reason "AI Review" "AI Review" "2026-10-01T10:00:00Z" "" "abc" ""
    [ "${status}" -eq 1 ]
}

# --- naming the next phase for an unchanged PR ------------------------------------------------------

@test "pr_next_phase_for_board_status routes a CANCELLED required check to PHASE C ahead of the board (#1432)" {
    local pr='{"isDraft":false,"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"CANCELLED","isRequired":true}]}'
    run pr_next_phase_for_board_status "Human Review" "${pr}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "PHASE C (fix the failed required check)" ]
}

@test "pr_next_phase_for_board_status names the phase each review-loop board status implies" {
    local pr='{"isDraft":true,"autoMergeRequest":null,"statusCheckRollup":[]}'
    run pr_next_phase_for_board_status "AI Simplify" "${pr}"
    [ "${output}" = "PHASE D (simplify)" ]
    run pr_next_phase_for_board_status "AI Review" "${pr}"
    [ "${output}" = "PHASE E (code review)" ]
    run pr_next_phase_for_board_status "AI Security Review" "${pr}"
    [ "${output}" = "PHASE F (security review)" ]
    run pr_next_phase_for_board_status "AI Coverage" "${pr}"
    [ "${output}" = "PHASE G (coverage)" ]
    run pr_next_phase_for_board_status "Human Review" "${pr}"
    [ "${output}" = "PHASE H (finalize)" ]
    run pr_next_phase_for_board_status "Development" "${pr}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PHASE D (simplify)"* ]]
}

@test "pr_next_phase_for_board_status puts a failed required check or requested changes ahead of the board" {
    run pr_next_phase_for_board_status "AI Review" '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${output}" = "PHASE C (fix the failed required check)" ]
    run pr_next_phase_for_board_status "AI Review" '{"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[]}'
    [ "${output}" = "PHASE C (address the requested changes)" ]
}

@test "pr_next_phase_for_board_status sends a failing check to PHASE C when the required-check lookup failed (#1557)" {
    local pr='{"autoMergeRequest":null,"statusCheckRollup":[{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE"}]}'
    run pr_next_phase_for_board_status "Human Review" "${pr}" true
    [ "${status}" -eq 0 ]
    [ "${output}" = "PHASE C (fix the failed check: whether it is required could not be looked up)" ]
    run pr_next_phase_for_board_status "Complete" "${pr}" true
    [ "${status}" -eq 0 ]
    [ "${output}" = "PHASE C (fix the failed check: whether it is required could not be looked up)" ]
    run pr_next_phase_for_board_status "Human Review" '{"autoMergeRequest":null,"statusCheckRollup":[{"context":"legacy","state":"ERROR"}]}' true
    [ "${output}" = "PHASE C (fix the failed check: whether it is required could not be looked up)" ]
    # A superseded failure no longer counts, as for pr_json_is_terminal.
    run pr_next_phase_for_board_status "Human Review" '{"autoMergeRequest":null,"statusCheckRollup":[{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-01T10:00:00Z"},{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-01T11:00:00Z"}]}' true
    [ "${output}" = "PHASE H (finalize)" ]
    run pr_next_phase_for_board_status "Human Review" "${pr}" false
    [ "${output}" = "PHASE H (finalize)" ]
}

@test "pr_next_phase_for_board_status names no phase for Complete or an unknown status, so the caller still invokes (#1557)" {
    run pr_next_phase_for_board_status "Complete" '{}'
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    run pr_next_phase_for_board_status "Unknown" '{}'
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
}

@test "pr_next_phase_for_board_status sends an armed but unmergeable Human Review PR back to PHASE C" {
    run pr_next_phase_for_board_status "Human Review" '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[]}'
    [ "${status}" -eq 0 ]
    [[ "${output}" == "PHASE C"* ]]
}

@test "plan_unchanged_pr_reinvocation invokes without a phase, and without touching the idle budget, when the board is Complete (#1557)" {
    discover_or_create_workflow_project() { return 0; }
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'Complete'; }
    pr_json='{"isDraft":true,"statusCheckRollup":[]}'
    pr_has_unaddressed_comment=false
    pr_next_phase="stale"
    save_pr_invocation_counts 42 7 2
    run plan_unchanged_pr_reinvocation 42 "org/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"board status 'Complete' names no phase, invoking without one"* ]]
    plan_unchanged_pr_reinvocation 42 "org/repo" > /dev/null
    [ -z "${pr_next_phase}" ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 7 ]
    [ "${PR_INVOCATION_IDLE}" -eq 2 ]
}

@test "plan_unchanged_pr_reinvocation names the phase for a draft mid-way through the review loop" {
    discover_or_create_workflow_project() { return 0; }
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'AI Review'; }
    pr_json='{"isDraft":true,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SKIPPED","isRequired":true}]}'
    pr_has_unaddressed_comment=false
    pr_next_phase=""
    plan_unchanged_pr_reinvocation 42 "org/repo"
    [ "${pr_next_phase}" = "PHASE E (code review)" ]
}

@test "plan_unchanged_pr_reinvocation invokes without a phase when an unaddressed comment comes first" {
    board_substatus_for_item() { printf 'Complete'; }
    pr_json='{}'
    pr_has_unaddressed_comment=true
    pr_next_phase="stale"
    plan_unchanged_pr_reinvocation 42 "org/repo"
    [ -z "${pr_next_phase}" ]
}

# --- main: progress accounting, required checks and the idle gate end to end -----------------------

# PR #5's state as fetch_pr_json returns it for these tests: an open, unblocked draft on feat/test at
# head abc, with the given top-level comments and statusCheckRollup (both default to empty).
draft_pr5_json() {
    printf '{"state":"OPEN","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":%s,"reviews":[],"statusCheckRollup":%s,"mergeStateStatus":"CLEAN"}\n' "${1:-[]}" "${2:-[]}"
}

# Stubs fetch_pr_json to return pre_state on its first call (the pre-session read) and post_state on
# every later call (the post-session re-read and any later tick), so a comment only in post_state
# was posted while the session ran. An empty post_state makes every later call fail.
stub_pr_json_pre_post() {
    printf '%s' "$1" > "${TEST_TMP}/pr_pre.json"
    printf '%s' "$2" > "${TEST_TMP}/pr_post.json"
    printf '0' > "${TEST_TMP}/_pr_json_calls"
    fetch_pr_json() {
        local _count
        _count=$(( $(cat "${TEST_TMP}/_pr_json_calls") + 1 ))
        printf '%d' "${_count}" > "${TEST_TMP}/_pr_json_calls"
        if [ "${_count}" -eq 1 ]; then
            cat "${TEST_TMP}/pr_pre.json"
            return 0
        fi
        [ -s "${TEST_TMP}/pr_post.json" ] || return 1
        cat "${TEST_TMP}/pr_post.json"
    }
}

# A direct-PR draft (PR #5, draft_pr5_json) whose fingerprint is unchanged and whose idle budget
# allows another try. fetch_pr_latest_trusted_comment_timestamp logs each call to comment_fetches
# and derives from the PR state main hands it, or from the test's own fetch_pr_json when none is
# handed over, honouring the exclude-login argument, so the bot exclusion and the reuse of the
# post-session re-read are exercised end to end.
setup_unchanged_direct_draft_pr() {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    get_trusted_logins() { printf '["credfeto","testuser"]\n'; }
    fetch_pr_json() { draft_pr5_json; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 2 2
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    fetch_pr_latest_trusted_comment_timestamp() {
        printf 'called\n' >> "${TEST_TMP}/comment_fetches"
        local _pr="${3:-}"
        [ -n "${_pr}" ] || _pr=$(fetch_pr_json "$1") || return 1
        pr_json_latest_trusted_comment_timestamp "${_pr}" "$(get_trusted_logins)" '[]' '[]' "${2:-}"
    }
}

@test "main charges idle and keeps the marker at the trusted comment when the session only posted its own comment" {
    setup_unchanged_direct_draft_pr
    stub_pr_json_pre_post \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z","body":"fix it"}]')" \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z","body":"fix it"},{"author":{"login":"testuser"},"createdAt":"2026-10-01T12:00:00Z","body":"Status: nothing to do"}]')"
    load_pr_last_agent_comment_seen() { printf '2026-10-01T10:00:00Z'; }
    save_pr_last_agent_comment_seen() { printf '%s' "$2" > "${TEST_TMP}/saved_marker"; }
    fetch_single_item_workflow_status() { printf 'AI Review'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: no progress this session"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
    [ "$(cat "${TEST_TMP}/saved_marker")" = "2026-10-01T10:00:00Z" ]
    # The comment timestamp came from the post-session re-read: no third PR read for it.
    [ "$(cat "${TEST_TMP}/_pr_json_calls")" -eq 2 ]
}

@test "main resets idle when a trusted commenter commented while the session ran" {
    setup_unchanged_direct_draft_pr
    stub_pr_json_pre_post "$(draft_pr5_json)" \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T12:00:00Z","body":"one more thing"}]')"
    fetch_single_item_workflow_status() { printf 'AI Review'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not charging this session against the idle budget (a trusted comment arrived during the session and is left unaddressed for the next run)"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "main alerts and records a stalled session when a PR session hit denials and made no progress" {
    setup_unchanged_direct_draft_pr
    stub_pr_json_pre_post "$(draft_pr5_json)" "$(draft_pr5_json)"
    fetch_single_item_workflow_status() { printf 'AI Review'; }
    orchestrator_today() { printf '2026-10-05'; }
    invoke_claude() { SESSION_DENIAL_COUNT=2; SESSION_DENIED_COMMANDS="git"; SESSION_TOOL_DENIED_QUIT=0; SESSION_RESULT_TEXT="done"; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: no progress this session"* ]]
    grep -q '^PullRequest 5 2 git done$' "${stalled_log}"
    [ "$(cut -f3- "${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05")" = "$(printf 'PullRequest\t5\t2\t1\t0\tgit')" ]
}

@test "main records but does not alert on a PR session with denials that made progress" {
    setup_unchanged_direct_draft_pr
    stub_pr_json_pre_post "$(draft_pr5_json)" \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T12:00:00Z","body":"one more thing"}]')"
    fetch_single_item_workflow_status() { printf 'AI Review'; }
    orchestrator_today() { printf '2026-10-05'; }
    invoke_claude() { SESSION_DENIAL_COUNT=2; SESSION_DENIED_COMMANDS="git"; SESSION_TOOL_DENIED_QUIT=0; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not charging this session against the idle budget"* ]]
    [ ! -f "${stalled_log}" ]
    [ "$(cut -f3- "${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05")" = "$(printf 'PullRequest\t5\t2\t0\t0\tgit')" ]
}

@test "main alerts on an Issue session that quit after a tool denial, with no progress information" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    orchestrator_today() { printf '2026-10-05'; }
    invoke_claude() { SESSION_DENIAL_COUNT=0; SESSION_DENIED_COMMANDS=""; SESSION_TOOL_DENIED_QUIT=1; SESSION_RESULT_TEXT="Bash is now denied"; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q '^Issue 10 0  Bash is now denied$' "${stalled_log}"
    [ "$(cut -f3- "${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05")" = "$(printf 'Issue\t10\t0\t1\t1\t-')" ]
}

@test "main records the session outcome before saving the counters, so a counter write that dies still leaves the record" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    orchestrator_today() { printf '2026-10-05'; }
    invoke_claude() { SESSION_DENIAL_COUNT=0; SESSION_DENIED_COMMANDS=""; SESSION_TOOL_DENIED_QUIT=1; SESSION_RESULT_TEXT="Bash is now denied"; }
    save_issue_invocation_counts() { die "Failed to write invocation guard file"; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to write invocation guard file"* ]]
    grep -q '^Issue 10 0  Bash is now denied$' "${stalled_log}"
    [ "$(cut -f3- "${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05")" = "$(printf 'Issue\t10\t0\t1\t1\t-')" ]
}

@test "main does not alert on an Issue session with denials that did not quit" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { SESSION_DENIAL_COUNT=3; SESSION_DENIED_COMMANDS="git"; SESSION_TOOL_DENIED_QUIT=0; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${stalled_log}" ]
}

@test "main runs the daily digest rollover for its owner even when there is no work" {
    setup_main_mocks
    fetch_all_priorities() { printf '[]\n'; }
    local rollover_log="${TEST_TMP}/rollover.log"
    run_daily_digest_rollover() { printf 'owner=%s\n' "$1" >> "${rollover_log}"; }

    run main --owner org
    [ "${status}" -eq 0 ]
    [ "$(cat "${rollover_log}")" = "owner=org" ]
}

# File-backed last-agent-comment-seen marker, so a test can run main for two ticks and observe what
# the first one saved (setup_main_mocks stubs both to no-ops), on top of stub_pr_json_pre_post.
use_file_backed_marker_and_pr_states() {
    stub_pr_json_pre_post "$1" "$2"
    save_pr_last_agent_comment_seen() { printf '%s' "$2" > "${TEST_TMP}/marker"; }
    load_pr_last_agent_comment_seen() { [ -f "${TEST_TMP}/marker" ] && cat "${TEST_TMP}/marker"; return 0; }
    build_pr_claude_md() { printf '%s' "${10}" > "${TEST_TMP}/comments_given"; printf 'mock-pr-claude-md\n'; }
    fetch_single_item_workflow_status() { printf 'AI Review'; }
}

@test "main does not mark a trusted comment posted during the session as seen, and the next tick is given it" {
    setup_unchanged_direct_draft_pr
    use_file_backed_marker_and_pr_states \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z","body":"fix it"}]')" \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z","body":"fix it"},{"author":{"login":"credfeto"},"createdAt":"2026-10-01T12:00:00Z","body":"one more thing"}]')"
    printf '2026-10-01T09:00:00Z' > "${TEST_TMP}/marker"

    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c called "${TEST_TMP}/claude_log")" -eq 1 ]
    grep -q 'fix it' "${TEST_TMP}/comments_given"
    [ "$(grep -c 'one more thing' "${TEST_TMP}/comments_given")" -eq 0 ]
    [ "$(cat "${TEST_TMP}/marker")" = "2026-10-01T10:00:00Z" ]
    [[ "${output}" == *"a trusted comment arrived during the session and is left unaddressed for the next run"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    run pr_json_has_unaddressed_trusted_comment "$(cat "${TEST_TMP}/pr_post.json")" '["credfeto","testuser"]' "$(cat "${TEST_TMP}/marker")" '[]' '[]' "testuser"
    [ "${status}" -eq 0 ]

    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c called "${TEST_TMP}/claude_log")" -eq 2 ]
    grep -q 'one more thing' "${TEST_TMP}/comments_given"
    [ "$(grep -c 'fix it' "${TEST_TMP}/comments_given")" -eq 0 ]
    [ "$(cat "${TEST_TMP}/marker")" = "2026-10-01T12:00:00Z" ]
}

@test "main marks the trusted comments the agent was given as seen" {
    setup_unchanged_direct_draft_pr
    local _state
    _state=$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z","body":"first"},{"author":{"login":"credfeto"},"createdAt":"2026-10-01T11:00:00Z","body":"second"}]')
    use_file_backed_marker_and_pr_states "${_state}" "${_state}"
    printf '2026-10-01T09:00:00Z' > "${TEST_TMP}/marker"

    run main
    [ "${status}" -eq 0 ]
    grep -q 'first' "${TEST_TMP}/comments_given"
    grep -q 'second' "${TEST_TMP}/comments_given"
    [ "$(cat "${TEST_TMP}/marker")" = "2026-10-01T11:00:00Z" ]
    run pr_json_has_unaddressed_trusted_comment "${_state}" '["credfeto","testuser"]' "2026-10-01T11:00:00Z" '[]' '[]' "testuser"
    [ "${status}" -eq 1 ]
}

@test "main never moves the marker for the orchestrator's own comments, before or during the session" {
    setup_unchanged_direct_draft_pr
    use_file_backed_marker_and_pr_states \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z","body":"fix it"},{"author":{"login":"testuser"},"createdAt":"2026-10-01T11:00:00Z","body":"Status: working"}]')" \
        "$(draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z","body":"fix it"},{"author":{"login":"testuser"},"createdAt":"2026-10-01T11:00:00Z","body":"Status: working"},{"author":{"login":"testuser"},"createdAt":"2026-10-01T12:00:00Z","body":"Status: done"}]')"
    printf '2026-10-01T09:00:00Z' > "${TEST_TMP}/marker"

    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'Status:' "${TEST_TMP}/comments_given")" -eq 0 ]
    [ "$(cat "${TEST_TMP}/marker")" = "2026-10-01T10:00:00Z" ]
    [[ "${output}" == *"PR #5 in org/repo: no progress this session"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
    run pr_json_has_unaddressed_trusted_comment "$(cat "${TEST_TMP}/pr_post.json")" '["credfeto","testuser"]' "$(cat "${TEST_TMP}/marker")" '[]' '[]' "testuser"
    [ "${status}" -eq 1 ]
}

@test "main does not save the marker and warns when the pre-session comment timestamp cannot be computed" {
    setup_unchanged_direct_draft_pr
    use_file_backed_marker_and_pr_states "$(draft_pr5_json)" "$(draft_pr5_json)"
    pr_json_latest_trusted_comment_timestamp() { return 1; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/marker" ]
    [[ "${output}" == *"Failed to compute the pre-session last-agent-comment-seen for PR #5 in org/repo"* ]]
}

@test "main charges idle and does not compare a post-session comment timestamp when the pre-session one failed" {
    setup_unchanged_direct_draft_pr
    use_file_backed_marker_and_pr_states "$(draft_pr5_json)" "$(draft_pr5_json)"
    pr_json_latest_trusted_comment_timestamp() { return 1; }
    fetch_pr_latest_trusted_comment_timestamp() {
        printf 'called\n' >> "${TEST_TMP}/comment_fetches"
        printf '2026-10-01T12:00:00Z'
    }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/comment_fetches" ]
    [[ "${output}" == *"PR #5 in org/repo: no progress this session"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
}

@test "main resets idle for a board move even when the post-session PR re-read fails, without fetching comments" {
    setup_unchanged_direct_draft_pr
    stub_pr_json_pre_post "$(draft_pr5_json)" ""
    local _board="${TEST_TMP}/_board_calls"
    printf '0' > "${_board}"
    fetch_single_item_workflow_status() {
        local _count
        _count=$(( $(cat "${_board}") + 1 ))
        printf '%d' "${_count}" > "${_board}"
        [ "${_count}" -eq 1 ] && printf 'AI Simplify' || printf 'AI Review'
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not charging this session against the idle budget (board moved from AI Simplify to AI Review)"* ]]
    [ ! -f "${TEST_TMP}/comment_fetches" ]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "main fetches the post-session comments itself when the post-session PR re-read failed and the board did not move" {
    setup_unchanged_direct_draft_pr
    stub_pr_json_pre_post "$(draft_pr5_json)" ""
    fetch_single_item_workflow_status() { printf 'AI Review'; }
    fetch_pr_latest_trusted_comment_timestamp() {
        printf '%s' "${3:-}" > "${TEST_TMP}/comment_fetch_pr_json"
        printf '2026-10-01T12:00:00Z'
    }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/comment_fetch_pr_json" ]
    [ ! -s "${TEST_TMP}/comment_fetch_pr_json" ]
    [[ "${output}" == *"not charging this session against the idle budget (a trusted comment arrived during the session and is left unaddressed for the next run)"* ]]
    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "main does not treat the orchestrator's own newer comment as unaddressed on a settled PR" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    get_trusted_logins() { printf '["credfeto","testuser"]\n'; }
    fetch_pr_json() { printf '{"state":"OPEN","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"testuser"},"createdAt":"2026-10-01T12:00:00Z","body":"ready"}],"reviews":[],"statusCheckRollup":[],"mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    load_pr_last_agent_comment_seen() { printf '2026-10-01T10:00:00Z'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main does not report a failed required check for a failing check GitHub says is optional" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    fetch_pr_required_check_names() { printf '["build"]'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    block_pr_for_idle_exhausted_failure() { return 0; }
    block_pr_for_idle_exhausted_no_progress() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"idle budget exhausted with no known blocking reason"* ]]
    [ "$(printf '%s\n' "${output}" | grep -c 'with a failed required check')" -eq 0 ]
}

@test "main tells the no-progress escalation when the required-check lookup failed (#1557)" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    block_pr_for_idle_exhausted_no_progress() { printf '%s\n' "${3:-}" > "${TEST_TMP}/required_checks_unknown"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to look up the required checks for PR #5"* ]]
    [ "$(cat "${TEST_TMP}/required_checks_unknown")" = "true" ]
}

@test "main reports a failed required check on a repo with no required checks (#1557)" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    fetch_pr_required_check_names() { printf '[]'; }
    fetch_branch_requires_status_checks() { printf 'false'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    block_pr_for_idle_exhausted_failure() { printf 'failure\n' >> "${TEST_TMP}/blocked"; }
    block_pr_for_idle_exhausted_no_progress() { printf 'no_progress\n' >> "${TEST_TMP}/blocked"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"idle budget exhausted with a failed required check"* ]]
    [ "$(cat "${TEST_TMP}/blocked")" = "failure" ]
}

@test "main invokes an unchanged PR at Complete with a failing check on a repo with no required checks (#1557)" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    fetch_pr_required_check_names() { printf '[]'; }
    fetch_branch_requires_status_checks() { printf 'false'; }
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'Complete'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"next phase is PHASE C (fix the failed required check)"* ]]
}

@test "main invokes an unchanged PR at Complete with a failing check when the required-check lookup failed (#1557)" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'Complete'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"next phase is PHASE C (fix the failed check: whether it is required could not be looked up)"* ]]
}

@test "main still reports a failed required check GitHub says is required" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    fetch_pr_required_check_names() { printf '["build"]'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    block_pr_for_idle_exhausted_failure() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"idle budget exhausted with a failed required check"* ]]
}

@test "main invokes an unchanged open PR whose board is Complete, without naming a phase (#1557)" {
    # Board sync raises a PR's card to its linked issues' highest status, so an open PR can read
    # Complete before its own work is done; it must still be invoked, as it was before the board
    # was consulted.
    setup_unchanged_direct_draft_pr
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'Complete'; }
    build_pr_claude_md() { printf '%s' "${11}" > "${TEST_TMP}/next_phase"; printf 'mock-pr-claude-md\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"board status 'Complete' names no phase, invoking without one"* ]]
    [[ "${output}" == *"PR #5 in org/repo unchanged "*"re-invoking to advance the next workflow phase"* ]]
    [ ! -s "${TEST_TMP}/next_phase" ]
}

@test "main waits for CI, rather than reporting a failed required check, when the base branch requires checks none of which has reported (#1557)" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    fetch_pr_required_check_names() { printf '[]'; }
    fetch_branch_requires_status_checks() { printf 'true'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    block_pr_for_idle_exhausted_failure() { printf 'failure\n' >> "${TEST_TMP}/blocked"; }
    block_pr_for_idle_exhausted_no_progress() { printf 'no_progress\n' >> "${TEST_TMP}/blocked"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: CI checks pending"* ]]
    [ ! -f "${TEST_TMP}/blocked" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main leaves required-ness unknown when the base-branch lookup fails (#1557)" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]'; }
    fetch_pr_required_check_names() { printf '[]'; }
    fetch_branch_requires_status_checks() { return 1; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    block_pr_for_idle_exhausted_failure() { printf 'failure\n' >> "${TEST_TMP}/blocked"; }
    block_pr_for_idle_exhausted_no_progress() { printf '%s\n' "${3:-}" > "${TEST_TMP}/required_checks_unknown"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to look up whether the base branch of PR #5 requires any check"* ]]
    [ ! -f "${TEST_TMP}/blocked" ]
    [ "$(cat "${TEST_TMP}/required_checks_unknown")" = "true" ]
}

@test "main hands an unchanged draft with passing required checks the next review-loop phase, without looking up required checks" {
    setup_unchanged_direct_draft_pr
    fetch_pr_json() { draft_pr5_json '[]' '[{"name":"build","status":"COMPLETED","conclusion":"SKIPPED"}]'; }
    fetch_pr_required_check_names() { printf 'called\n' >> "${TEST_TMP}/required_lookups"; printf '["build"]'; }
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'AI Review'; }
    build_pr_claude_md() { printf '%s' "${11}" > "${TEST_TMP}/next_phase"; printf 'mock-pr-claude-md\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"board status 'AI Review', next phase is PHASE E (code review)"* ]]
    [ "$(cat "${TEST_TMP}/next_phase")" = "PHASE E (code review)" ]
    [ ! -f "${TEST_TMP}/required_lookups" ]
}

@test "main passes the unaddressed trusted comment text into the PR CLAUDE.md" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { draft_pr5_json '[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T12:00:00Z","body":"Did you fix the reference errors?"}]'; }
    load_pr_last_agent_comment_seen() { printf '2026-10-01T10:00:00Z'; }
    build_pr_claude_md() { printf '%s' "${10}" > "${TEST_TMP}/comments"; printf 'mock-pr-claude-md\n'; }
    invoke_claude() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'Did you fix the reference errors?' "${TEST_TMP}/comments"
}

@test "build_pr_claude_md still offers the discard route for leftovers on an unrelated branch" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "feat/x" "/w" "fix/other" "false" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"git -C /w reset HEAD"* ]]
}
