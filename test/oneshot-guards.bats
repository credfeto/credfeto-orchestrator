#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- parse_two_token_counters (shared by load_pr_invocation_counts / load_issue_invocation_counts, #1264) ---

@test "parse_two_token_counters extracts both tokens from a matching line" {
    parse_two_token_counters "7 3"
    [ "${_PARSED_COUNT_TOTAL}" -eq 7 ]
    [ "${_PARSED_COUNT_IDLE}" -eq 3 ]
}

@test "parse_two_token_counters fails and zeroes both outputs for a single-token line" {
    _PARSED_COUNT_TOTAL=9
    _PARSED_COUNT_IDLE=9
    local parse_rc=0
    parse_two_token_counters "7" || parse_rc=$?
    [ "${parse_rc}" -ne 0 ]
    [ "${_PARSED_COUNT_TOTAL}" -eq 0 ]
    [ "${_PARSED_COUNT_IDLE}" -eq 0 ]
}

@test "parse_two_token_counters fails for garbage input" {
    run parse_two_token_counters "garbage not numbers"
    [ "${status}" -ne 0 ]
}

# --- per-PR invocation guard -----------------------------------------------

@test "load_pr_invocation_counts defaults to 0/0 when no guard file exists" {
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "save_pr_invocation_counts and load_pr_invocation_counts round-trip" {
    save_pr_invocation_counts 42 7 3
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.invocations" ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 7 ]
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
}

@test "load_pr_invocation_counts treats a corrupt guard file as 0/0" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'garbage not numbers\n' > "${SESSION_BASE_DIR}/PullRequest_42.invocations"
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "load_pr_invocation_counts treats a single-token guard file as 0/0, not aliased into both counters (#1103)" {
    mkdir -p "${SESSION_BASE_DIR}"
    # A single lone token used to alias into BOTH total and idle via independent
    # ${line%% *}/${line##* *} extraction — total=7 idle=7 would instantly exhaust a 5-idle
    # budget for a PR that was never actually invoked 7 times.
    printf '7\n' > "${SESSION_BASE_DIR}/PullRequest_42.invocations"
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

# --- consecutive infra-failure guard (#1133 review) -----------------------------

@test "load_infra_failure_count defaults to 0 when no guard file exists" {
    load_infra_failure_count "Issue" 42
    [ "${INFRA_FAILURE_COUNT}" -eq 0 ]
}

@test "save_infra_failure_count and load_infra_failure_count round-trip" {
    save_infra_failure_count "Issue" 42 3
    [ -f "${SESSION_BASE_DIR}/Issue_42.infra-failures" ]
    load_infra_failure_count "Issue" 42
    [ "${INFRA_FAILURE_COUNT}" -eq 3 ]
}

@test "load_infra_failure_count treats a corrupt guard file as 0" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'garbage\n' > "${SESSION_BASE_DIR}/PullRequest_42.infra-failures"
    load_infra_failure_count "PullRequest" 42
    [ "${INFRA_FAILURE_COUNT}" -eq 0 ]
}

@test "clear_infra_failure_count removes the guard file" {
    save_infra_failure_count "Issue" 42 3
    clear_infra_failure_count "Issue" 42
    [ ! -f "${SESSION_BASE_DIR}/Issue_42.infra-failures" ]
}

@test "clear_infra_failure_count is a no-op when no guard file exists" {
    run clear_infra_failure_count "Issue" 999
    [ "${status}" -eq 0 ]
}

@test "reset_pr_invocation_counts_if_capped resets and clears the marker when the runaway-blocked marker is present and a live re-check confirms unblocked (#1310)" {
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 3
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked"
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    run reset_pr_invocation_counts_if_capped 42 "org/repo"
    [ "${status}" -eq 0 ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "reset_pr_invocation_counts_if_capped leaves the total untouched when no runaway-blocked marker exists" {
    save_pr_invocation_counts 42 5 3
    run reset_pr_invocation_counts_if_capped 42 "org/repo"
    [ "${status}" -eq 0 ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 5 ]
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
}

@test "reset_pr_invocation_counts_if_capped does not reset a total that just now reached the cap without a marker" {
    # Regression guard: the tick the backstop is ABOUT to trip on has total >= cap but no marker
    # yet (the marker is only written once the block is actually applied). Resetting here would
    # erase the counter before the backstop ever gets to fire, defeating the cap entirely.
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    run reset_pr_invocation_counts_if_capped 42 "org/repo"
    [ "${status}" -eq 0 ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq "${MAX_PR_TOTAL_INVOCATIONS}" ]
}

@test "reset_pr_invocation_counts_if_capped does NOT reset and returns 1 when the marker is present but a live re-check still finds the Blocked label (#1310 stale-read regression)" {
    # Reproduces the #1310 race: a runaway-blocked marker is present (a prior tick applied and
    # verified Blocked), but this tick's already-fetched JSON is a stale read that lags behind
    # that verified write and shows the item as unblocked. The direct live re-check must catch
    # this and refuse the reset, leaving both the marker and the counters untouched.
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 3
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked"
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    run reset_pr_invocation_counts_if_capped 42 "org/repo"
    [ "${status}" -eq 1 ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq "${MAX_PR_TOTAL_INVOCATIONS}" ]
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "reset_pr_invocation_counts_if_capped does NOT reset when the marker is present and the live re-check itself fails (fail-safe, #1310)" {
    # A gh error/empty response must not be treated as confirmation of "unblocked" — that would
    # defeat the whole point of re-checking. It must defer, exactly like a confirmed-still-blocked
    # read, rather than falling back to trusting the original (already-suspect) cached reading.
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked"
    make_stub gh 'exit 1'
    run reset_pr_invocation_counts_if_capped 42 "org/repo"
    [ "${status}" -eq 1 ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq "${MAX_PR_TOTAL_INVOCATIONS}" ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

# --- per-Issue invocation guard ----------------------------------------------

@test "load_issue_invocation_counts defaults to 0/0 when no guard file exists" {
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "save_issue_invocation_counts and load_issue_invocation_counts round-trip" {
    save_issue_invocation_counts 99 4 2
    [ -f "${SESSION_BASE_DIR}/Issue_99.invocations" ]
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 4 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 2 ]
}

@test "load_issue_invocation_counts treats a corrupt guard file as 0/0" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'garbage not numbers\n' > "${SESSION_BASE_DIR}/Issue_99.invocations"
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "load_issue_invocation_counts treats a legacy single-token guard file as total-only, idle 0 (#1264)" {
    # Pre-#1264 guard files hold only "<total>" (Issues had no idle counter until #1264 added
    # one) — must parse the total correctly and default idle to 0, not treat the whole file as
    # corrupt (that would silently discard real invocation history on every repo already running
    # before this change).
    mkdir -p "${SESSION_BASE_DIR}"
    printf '7\n' > "${SESSION_BASE_DIR}/Issue_99.invocations"
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 7 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "load_issue_invocation_counts recovers total from a torn/corrupted line with trailing junk after a numeric total" {
    # A partial/torn write (crash mid-write, disk full) can leave a numeric total followed by
    # garbage rather than a clean second token. Recovering total here (idle defaults to 0) does
    # not reintroduce the #1103 aliasing bug, since idle is never derived from the trailing junk.
    mkdir -p "${SESSION_BASE_DIR}"
    printf '7 gar\n' > "${SESSION_BASE_DIR}/Issue_99.invocations"
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 7 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "reset_issue_invocation_counts_if_capped resets both counters and clears the marker when the runaway-blocked marker is present and a live re-check confirms unblocked (#1310)" {
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 3
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_99.runaway-blocked"
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    run reset_issue_invocation_counts_if_capped 99 "org/repo"
    [ "${status}" -eq 0 ]
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "reset_issue_invocation_counts_if_capped leaves the counters untouched when no runaway-blocked marker exists" {
    save_issue_invocation_counts 99 5 2
    run reset_issue_invocation_counts_if_capped 99 "org/repo"
    [ "${status}" -eq 0 ]
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 5 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 2 ]
}

@test "reset_issue_invocation_counts_if_capped does not reset a total that just now reached the cap without a marker" {
    # Regression guard: same rationale as the PR-side test — a not-yet-blocked Issue whose total
    # just reached the cap must not be reset before the backstop gets a chance to fire.
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    run reset_issue_invocation_counts_if_capped 99 "org/repo"
    [ "${status}" -eq 0 ]
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq "${MAX_ISSUE_TOTAL_INVOCATIONS}" ]
}

@test "reset_issue_invocation_counts_if_capped does NOT reset and returns 1 when the marker is present but a live re-check still finds the Blocked label (#1310 stale-read regression)" {
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 3
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_99.runaway-blocked"
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    run reset_issue_invocation_counts_if_capped 99 "org/repo"
    [ "${status}" -eq 1 ]
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq "${MAX_ISSUE_TOTAL_INVOCATIONS}" ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 3 ]
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

# --- mark_capped_block_for_forgiveness (#1115) ------------------------------

@test "mark_capped_block_for_forgiveness writes the marker for a PR at the cap" {
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mark_capped_block_for_forgiveness PullRequest 42
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness does not write the marker for a PR below the cap" {
    save_pr_invocation_counts 42 5 0
    mark_capped_block_for_forgiveness PullRequest 42
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness writes the marker for an Issue at the cap" {
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    mark_capped_block_for_forgiveness Issue 99
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness does not write the marker for an Issue below the cap" {
    save_issue_invocation_counts 99 5 0
    mark_capped_block_for_forgiveness Issue 99
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness then reset forgives a PR blocked by a non-backstop rule (#1115 regression)" {
    # Reproduces the #116 bug: a PR blocked by something other than oneshot's own backstop (e.g.
    # the code-review workflow's "3+ rounds" rule) while its total already sits at the cap. Before
    # this fix, no marker existed for that block, so a human clearing the label was a no-op and
    # the very next observe-unblocked tick found the same stale total.
    save_pr_invocation_counts 116 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mark_capped_block_for_forgiveness PullRequest 116
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    reset_pr_invocation_counts_if_capped 116 "org/repo"
    load_pr_invocation_counts 116
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness writes the marker for a PR at the idle cap even when total is well below its cap (#1264 review)" {
    save_pr_invocation_counts 42 4 "${MAX_PR_IDLE_INVOCATIONS}"
    mark_capped_block_for_forgiveness PullRequest 42
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness writes the marker for an Issue at the idle cap even when total is well below its cap (#1264 review)" {
    save_issue_invocation_counts 99 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    mark_capped_block_for_forgiveness Issue 99
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness then reset forgives an Issue blocked purely by idle exhaustion (#1264 review)" {
    # Without checking the idle cap, docs/oneshot.md's claim that "both caps reset automatically
    # once a human clears Blocked" was false for an idle-only block: no marker meant clearing the
    # label was a no-op, and the still-unchanged fingerprint re-blocked the Issue on the very next
    # tick.
    save_issue_invocation_counts 99 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    mark_capped_block_for_forgiveness Issue 99
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    reset_issue_invocation_counts_if_capped 99 "org/repo"
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

# --- issue_plan_block marker (#1286) ----------------------------------------

@test "issue_plan_block_marked is false when no marker file exists" {
    run issue_plan_block_marked 42
    [ "${status}" -ne 0 ]
}

@test "mark_issue_plan_block writes the marker and issue_plan_block_marked then reports it" {
    mark_issue_plan_block 42
    [ -f "${SESSION_BASE_DIR}/Issue_42.plan-block" ]
    run issue_plan_block_marked 42
    [ "${status}" -eq 0 ]
}

@test "clear_issue_plan_block_marker removes the marker" {
    mark_issue_plan_block 42
    clear_issue_plan_block_marker 42
    [ ! -f "${SESSION_BASE_DIR}/Issue_42.plan-block" ]
    run issue_plan_block_marked 42
    [ "${status}" -ne 0 ]
}

@test "clear_issue_plan_block_marker is a no-op when no marker exists" {
    run clear_issue_plan_block_marker 42
    [ "${status}" -eq 0 ]
}

# --- fingerprinting --------------------------------------------------------

@test "hash_sha256 is deterministic and matches the known SHA-256 of 'hello'" {
    run bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "hello" | hash_sha256'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

# --- last-diagnostic marker (lib/state, #1448) ----------------------------------

@test "load_last_diagnostic is empty when no marker file exists" {
    run load_last_diagnostic "Issue" "42"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "save_last_diagnostic then load_last_diagnostic round-trips" {
    save_last_diagnostic "Issue" "42" "- Bash: git status"
    run load_last_diagnostic "Issue" "42"
    [ "${status}" -eq 0 ]
    [ "${output}" = "- Bash: git status" ]
}

@test "clear_last_diagnostic removes the marker" {
    save_last_diagnostic "PullRequest" "7" "- Bash: git status"
    clear_last_diagnostic "PullRequest" "7"
    run load_last_diagnostic "PullRequest" "7"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "clear_last_diagnostic is a no-op when no marker exists" {
    run clear_last_diagnostic "Issue" "99"
    [ "${status}" -eq 0 ]
}

@test "last-diagnostic marker is keyed independently per item type and id" {
    save_last_diagnostic "Issue" "1" "- Bash: git status"
    run load_last_diagnostic "PullRequest" "1"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run load_last_diagnostic "Issue" "2"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# --- record_last_session_diagnostic (#1448) -------------------------------------

@test "record_last_session_diagnostic persists the denials summary when one is passed" {
    record_last_session_diagnostic "Issue" "42" "some unrelated result text" "- Bash: git status"
    run load_last_diagnostic "Issue" "42"
    [ "${output}" = "- Bash: git status" ]
}

@test "record_last_session_diagnostic falls back to result_text when it matches the refusal heuristic" {
    record_last_session_diagnostic "Issue" "42" "git push is denied by the permission system" ""
    run load_last_diagnostic "Issue" "42"
    [ "${output}" = "git push is denied by the permission system" ]
}

@test "record_last_session_diagnostic clears the marker on an ordinary successful result" {
    save_last_diagnostic "Issue" "42" "stale diagnostic from a previous session"
    record_last_session_diagnostic "Issue" "42" "Implemented the feature and pushed the commit." ""
    run load_last_diagnostic "Issue" "42"
    [ -z "${output}" ]
}

@test "record_last_session_diagnostic persists a denials summary even when the run is later flagged is_error (#1448)" {
    # Called from invoke_claude before handle_claude_is_error's possible die, so a run that both
    # had denials and ended in error still gets its diagnostic persisted.
    record_last_session_diagnostic "PullRequest" "7" "some error-ish result text" "- Bash: git push"
    run load_last_diagnostic "PullRequest" "7"
    [ "${output}" = "- Bash: git push" ]
}

# --- append_last_diagnostic_to_reason (#1448) -----------------------------------

@test "append_last_diagnostic_to_reason returns the reason unchanged when no marker exists" {
    run append_last_diagnostic_to_reason "Issue" "42" "Generic block reason."
    [ "${status}" -eq 0 ]
    [ "${output}" = "Generic block reason." ]
}

@test "append_last_diagnostic_to_reason appends the fenced marker text when present" {
    save_last_diagnostic "Issue" "42" "- Bash: git status"
    run append_last_diagnostic_to_reason "Issue" "42" "Generic block reason."
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Generic block reason."* ]]
    [[ "${output}" == *"Last session's diagnostic:"* ]]
    [[ "${output}" == *'```'* ]]
    [[ "${output}" == *"- Bash: git status"* ]]
}

@test "append_last_diagnostic_to_reason truncates an oversized diagnostic" {
    local long_diagnostic
    long_diagnostic=$(printf 'x%.0s' $(seq 1 1000))
    save_last_diagnostic "Issue" "42" "${long_diagnostic}"
    run append_last_diagnostic_to_reason "Issue" "42" "Generic block reason."
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"... (truncated; see the run log for the full list)"* ]]
    [[ "${output}" != *"${long_diagnostic}"* ]]
}

@test "append_last_diagnostic_to_reason neutralises a diagnostic containing a fence-breaking backtick run" {
    save_last_diagnostic "Issue" "42" $'Bash: cat <<EOF\n```\n@someone please see #999\n```\nEOF'
    run append_last_diagnostic_to_reason "Issue" "42" "Generic block reason."
    [ "${status}" -eq 0 ]
    # Exactly the opening and closing fence this function itself adds - no fence survives from
    # the diagnostic content to prematurely close the block and un-fence "@someone"/"#999".
    [ "$(grep -c '```' <<<"${output}")" -eq 2 ]
    [[ "${output}" == *"@someone please see #999"* ]]
}

# --- background-stall marker (lib/state, #1326/#1335) ---------------------------

@test "background_stall_marked is false when no marker file exists" {
    run background_stall_marked "Issue" "42"
    [ "${status}" -ne 0 ]
}

@test "mark_background_stall then background_stall_marked round-trips" {
    mark_background_stall "Issue" "42"
    run background_stall_marked "Issue" "42"
    [ "${status}" -eq 0 ]
}

@test "clear_background_stall_marker removes the marker" {
    mark_background_stall "PullRequest" "7"
    clear_background_stall_marker "PullRequest" "7"
    run background_stall_marked "PullRequest" "7"
    [ "${status}" -ne 0 ]
}

@test "clear_background_stall_marker is a no-op when no marker exists" {
    run clear_background_stall_marker "Issue" "99"
    [ "${status}" -eq 0 ]
}

@test "background_stall marker is keyed independently per item type and id" {
    mark_background_stall "Issue" "1"
    run background_stall_marked "PullRequest" "1"
    [ "${status}" -ne 0 ]
    run background_stall_marked "Issue" "2"
    [ "${status}" -ne 0 ]
}

# A gh stand-in good enough for the in-repo cfwf to create an issue through: every call's arguments
# are logged one per line to $1, `gh issue list` finds no open tracker, and the rest answer the way a
# repo with a Workflow board and no labels would. The file cfwf passes as --body-file is copied to
# ${TEST_TMP}/cfwf_fixtures/issue-body.txt. Pass "fail" as $2 to make `gh issue create` fail.
make_cfwf_gh_stub() {
    local gh_log="$1" issue_create_result="${2:-ok}"
    local fixtures="${TEST_TMP}/cfwf_fixtures"
    mkdir -p "${fixtures}"
    jq -n '{projectsV2: {Nodes: [{id: "PVT_proj", title: "Workflow", number: 74, resourcePath: "/users/credfeto/projects/74", closed: false}]}}' > "${fixtures}/repo-view.json"
    jq -n '{fields: [
        {id: "PVTSSF_status", name: "Status", options: [{id: "todo", name: "Todo"}], type: "ProjectV2SingleSelectField"},
        {id: "PVTSSF_wf", name: "Workflow Status", options: [{id: "ns", name: "Not Started"}], type: "ProjectV2SingleSelectField"}]}' > "${fixtures}/field-list.json"
    jq -n '[]' > "${fixtures}/label-list.json"
    jq -n '{id: "PVTI_new"}' > "${fixtures}/item-add.json"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> '${gh_log}'
jq_expr=""; prev=""
for arg in "\$@"; do [ "\${prev}" = "--jq" ] && jq_expr="\${arg}"; prev="\${arg}"; done
emit() { if [ -n "\${jq_expr}" ]; then jq -r "\${jq_expr}" < "\$1"; else cat "\$1"; fi; }
case "\$1 \$2" in
  "issue list") exit 0 ;;
  "repo view") emit '${fixtures}/repo-view.json' ;;
  "project field-list") emit '${fixtures}/field-list.json' ;;
  "label list") emit '${fixtures}/label-list.json' ;;
  "issue create")
    prev=""
    for arg in "\$@"; do [ "\${prev}" = "--body-file" ] && cp "\${arg}" '${fixtures}/issue-body.txt'; prev="\${arg}"; done
    [ '${issue_create_result}' = "fail" ] && exit 1
    echo "https://github.com/credfeto/credfeto-orchestrator/issues/1600" ;;
  "project item-add") emit '${fixtures}/item-add.json' ;;
  *) exit 0 ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/gh"
}

@test "the rate-limit tracker issue title carries the oneshot scope and is exactly the text the open tracker is found by" {
    [ "${RATE_LIMIT_ISSUE_TITLE}" = "oneshot: Unparseable Claude rate-limit reset time" ]
}

@test "the rate-limit tracker repository is one whose issue titles the in-repository cfwf checks, so the check is not passed trivially, and the tracker title has the shape cfwf requires there" {
    run bash -c 'source "$1"; CURRENT_COMMAND="issue create"; title_check_applies "$3" && check_title_shape "$2" "$3"' \
        _ "${CFWF_SCRIPT}" "${RATE_LIMIT_ISSUE_TITLE}" "${RATE_LIMIT_ISSUE_REPO}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "report_unparseable_rate_limit creates a new issue, on the Workflow board, when no open tracking issue exists" {
    local gh_log="${TEST_TMP}/gh_args"
    make_cfwf_gh_stub "${gh_log}"

    local raw_msg="Rate limit reached - unknown format with no reset time"
    report_unparseable_rate_limit "Issue" "7" "${raw_msg}"

    [ -f "${gh_log}" ]
    # gh issue create must have been called with the expected flags, through cfwf.
    grep -q "^create$" "${gh_log}"
    grep -q "^${RATE_LIMIT_ISSUE_TITLE}$" "${gh_log}"
    grep -q "^AI-Work$" "${gh_log}"
    grep -q "^Medium$" "${gh_log}"
    grep -q "^${RATE_LIMIT_ISSUE_REPO}$" "${gh_log}"
    # The issue is put on the board.
    grep -q "^item-add$" "${gh_log}"
    # The verbatim raw message must appear in the body cfwf handed to gh.
    grep -q "${raw_msg}" "${TEST_TMP}/cfwf_fixtures/issue-body.txt"
    # gh issue comment must NOT have been called.
    run grep -q "^comment$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "oneshot sets BASEDIR to its own directory, and lib/globals builds the cfwf path from it" {
    [ "${BASEDIR}" = "${REPO_ROOT}" ]
    [ "${CFWF_SCRIPT}" = "${BASEDIR}/containers/base/development-full/scripts/cfwf" ]
}

@test "lib/globals takes the cfwf path from BASEDIR and stops loudly when BASEDIR is not set" {
    run bash -c 'BASEDIR=/some/dir; source "$1"; printf "%s" "${CFWF_SCRIPT}"' _ "${REPO_ROOT}/lib/globals"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/some/dir/containers/base/development-full/scripts/cfwf" ]

    run bash -c 'unset BASEDIR; source "$1"' _ "${REPO_ROOT}/lib/globals"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"BASEDIR must be set by the script that sources lib/globals"* ]]
}

@test "report_unparseable_rate_limit runs the cfwf in this repository and ignores one on PATH" {
    local gh_log="${TEST_TMP}/gh_args"
    make_cfwf_gh_stub "${gh_log}"
    make_stub cfwf "touch '${TEST_TMP}/decoy_cfwf_ran'"

    report_unparseable_rate_limit "Issue" "7" "Rate limit reached - unknown format"

    [ -x "${CFWF_SCRIPT}" ]
    [ "${CFWF_SCRIPT}" = "${REPO_ROOT}/containers/base/development-full/scripts/cfwf" ]
    [ ! -f "${TEST_TMP}/decoy_cfwf_ran" ]
    grep -q "^create$" "${gh_log}"
}

@test "report_unparseable_rate_limit warns and carries on when the issue cannot be created" {
    local gh_log="${TEST_TMP}/gh_args"
    make_cfwf_gh_stub "${gh_log}" fail

    run report_unparseable_rate_limit "Issue" "7" "Rate limit reached - unknown format"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to create unparseable rate-limit tracking issue: cfwf: could not create the issue in ${RATE_LIMIT_ISSUE_REPO}"* ]]
    run grep -q "^item-add$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "report_unparseable_rate_limit warns, saying why, when cfwf cannot find a Workflow board" {
    local gh_log="${TEST_TMP}/gh_args"
    make_cfwf_gh_stub "${gh_log}"
    jq -n '{projectsV2: {Nodes: []}}' > "${TEST_TMP}/cfwf_fixtures/repo-view.json"

    run report_unparseable_rate_limit "Issue" "7" "Rate limit reached - unknown format"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no project titled Workflow is linked to ${RATE_LIMIT_ISSUE_REPO}"* ]]
    run grep -q "^create$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "report_unparseable_rate_limit warns, naming the path, when the cfwf script is missing" {
    local gh_log="${TEST_TMP}/gh_args"
    make_cfwf_gh_stub "${gh_log}"
    CFWF_SCRIPT="${TEST_TMP}/no-such-cfwf"

    run report_unparseable_rate_limit "Issue" "7" "Rate limit reached - unknown format"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf not found at ${TEST_TMP}/no-such-cfwf"* ]]
}

@test "report_unparseable_rate_limit appends to existing open tracking issue" {
    local tracker_number=99
    local gh_log="${TEST_TMP}/gh_args"
    # Stub: gh issue list outputs just the issue number (simulating jq-filtered output from gh).
    # All other gh calls (issue comment) have their args logged.
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
    printf '%s\n' '${tracker_number}'
    exit 0
fi
printf '%s\n' "\$@" >> '${gh_log}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"

    local raw_msg="Some brand-new unparseable Claude 429 message"
    report_unparseable_rate_limit "PullRequest" "15" "${raw_msg}"

    [ -f "${gh_log}" ]
    # gh issue comment must have been called with the existing issue number.
    grep -q "^comment$" "${gh_log}"
    grep -q "^${tracker_number}$" "${gh_log}"
    # The verbatim raw message must appear in the body.
    grep -q "${raw_msg}" "${gh_log}"
    # gh issue create must NOT have been called.
    run grep -q "^create$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

# A gh stand-in for an existing open tracker #99: `gh issue list` finds it, `gh issue view` prints
# $2 as the tracker's body/comment text (or fails when $3 is "fail"), and every other call's
# arguments are logged one per line to $1.
make_existing_tracker_gh_stub() {
    local gh_log="$1" tracker_text="$2" view_result="${3:-ok}"
    printf '%s\n' "${tracker_text}" > "${TEST_TMP}/tracker_text"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "issue list") printf '%s\n' '99' ;;
  "issue view")
    [ '${view_result}' = "fail" ] && exit 1
    cat '${TEST_TMP}/tracker_text' ;;
  *) printf '%s\n' "\$@" >> '${gh_log}' ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/gh"
}

@test "report_unparseable_rate_limit does not comment when the message is already in the open tracking issue" {
    local gh_log="${TEST_TMP}/gh_args"
    local raw_msg="Already reported unparseable Claude 429 message"
    make_existing_tracker_gh_stub "${gh_log}" $'Earlier report\n```\nAlready reported unparseable Claude 429 message\n```'

    run report_unparseable_rate_limit "PullRequest" "15" "${raw_msg}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Rate-limit message already reported in issue #99"* ]]
    [ ! -f "${gh_log}" ]
}

@test "report_unparseable_rate_limit comments when the message is absent from the open tracking issue" {
    local gh_log="${TEST_TMP}/gh_args"
    local raw_msg="Brand-new unparseable Claude 429 message"
    make_existing_tracker_gh_stub "${gh_log}" $'Earlier report\n```\nSome other message\n```'

    run report_unparseable_rate_limit "PullRequest" "15" "${raw_msg}"
    [ "${status}" -eq 0 ]
    grep -q "^comment$" "${gh_log}"
    grep -q "^99$" "${gh_log}"
    grep -q "${raw_msg}" "${gh_log}"
}

@test "report_unparseable_rate_limit warns, fails and does not comment when the tracking issue cannot be read" {
    local gh_log="${TEST_TMP}/gh_args"
    make_existing_tracker_gh_stub "${gh_log}" "" fail

    run report_unparseable_rate_limit "PullRequest" "15" "Brand-new unparseable Claude 429 message"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to read issue #99"* ]]
    [ ! -f "${gh_log}" ]
}

# --- rate-limit file management -----------------------------------------------

@test "is_owner_rate_limited returns false when no rate-limit file exists" {
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
}

@test "is_owner_rate_limited returns true when file has a future timestamp" {
    local future_unix
    future_unix=$(( $(date +%s) + 3600 ))
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/${OWNER}"
    printf '%s\n' "${future_unix}" > "${ORCHESTRATOR_STATE_DIR}/${OWNER}/rate-limit"
    run is_owner_rate_limited
    [ "${status}" -eq 0 ]
}

@test "is_owner_rate_limited returns false and removes file when timestamp is in the past" {
    local past_unix
    past_unix=$(( $(date +%s) - 60 ))
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/${OWNER}"
    local rate_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/rate-limit"
    printf '%s\n' "${past_unix}" > "${rate_file}"
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
    [ ! -f "${rate_file}" ]
}

@test "is_owner_rate_limited returns false and removes file when content is non-numeric" {
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/${OWNER}"
    local rate_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/rate-limit"
    printf 'not-a-number\n' > "${rate_file}"
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
    [ ! -f "${rate_file}" ]
}

# --- pull_duration state helpers (#1400) --------------------------------------

@test "record_pull_duration appends a duration to the owner's state file" {
    OWNER="owner"
    record_pull_duration 42
    [ -f "${ORCHESTRATOR_STATE_DIR}/owner/pull-durations" ]
    [ "$(cat "${ORCHESTRATOR_STATE_DIR}/owner/pull-durations")" = "42" ]
}

@test "record_pull_duration caps history at PULL_DURATION_HISTORY_SIZE, keeping the most recent" {
    OWNER="owner"
    PULL_DURATION_HISTORY_SIZE=3
    record_pull_duration 1
    record_pull_duration 2
    record_pull_duration 3
    record_pull_duration 4
    [ "$(cat "${ORCHESTRATOR_STATE_DIR}/owner/pull-durations")" = "$(printf '2\n3\n4')" ]
}

@test "pull_duration_baseline fails when no samples are recorded" {
    OWNER="owner"
    run pull_duration_baseline
    [ "${status}" -ne 0 ]
}

@test "pull_duration_baseline fails when fewer than PULL_DURATION_MIN_SAMPLES are recorded" {
    OWNER="owner"
    PULL_DURATION_MIN_SAMPLES=5
    record_pull_duration 10
    record_pull_duration 10
    run pull_duration_baseline
    [ "${status}" -ne 0 ]
}

@test "pull_duration_baseline returns the median once PULL_DURATION_MIN_SAMPLES are recorded" {
    OWNER="owner"
    PULL_DURATION_MIN_SAMPLES=3
    record_pull_duration 30
    record_pull_duration 10
    record_pull_duration 20
    run pull_duration_baseline
    [ "${status}" -eq 0 ]
    [ "${output}" = "20" ]
}

# --- pull_duration_exceeds_baseline (#1400 review) -----------------------------

@test "pull_duration_exceeds_baseline fails when there is no trusted baseline yet" {
    OWNER="owner"
    PULL_DURATION_MIN_SAMPLES=3
    record_pull_duration 10
    run pull_duration_exceeds_baseline 600
    [ "${status}" -ne 0 ]
}

@test "pull_duration_exceeds_baseline fails when the pull is not disproportionately slower" {
    OWNER="owner"
    PULL_DURATION_MIN_SAMPLES=3
    PULL_DURATION_THRESHOLD_MULTIPLIER=3
    record_pull_duration 10
    record_pull_duration 10
    record_pull_duration 10
    run pull_duration_exceeds_baseline 20
    [ "${status}" -ne 0 ]
}

@test "pull_duration_exceeds_baseline succeeds and echoes the baseline when the pull is disproportionately slower" {
    OWNER="owner"
    PULL_DURATION_MIN_SAMPLES=3
    PULL_DURATION_THRESHOLD_MULTIPLIER=3
    record_pull_duration 10
    record_pull_duration 10
    record_pull_duration 10
    run pull_duration_exceeds_baseline 40
    [ "${status}" -eq 0 ]
    [ "${output}" = "10" ]
}

@test "pull_duration_exceeds_baseline fails on a zero-second baseline rather than flagging every nonzero pull (#1400 review)" {
    # date +%s has 1-second resolution: an owner whose last few pulls all rounded to 0s would
    # otherwise see any nonzero-duration pull satisfy "> 0 * PULL_DURATION_THRESHOLD_MULTIPLIER".
    OWNER="owner"
    PULL_DURATION_MIN_SAMPLES=3
    PULL_DURATION_THRESHOLD_MULTIPLIER=3
    record_pull_duration 0
    record_pull_duration 0
    record_pull_duration 0
    run pull_duration_exceeds_baseline 1
    [ "${status}" -ne 0 ]
}
