#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- environment-block auto-unblock (#1118) ---------------------------------

@test "pr_json_env_block_image_sha extracts the sha from a single marker comment" {
    run pr_json_env_block_image_sha '{"comments":[{"body":"Diagnosis text\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -eq 0 ]
    [ "${output}" = "abc1234" ]
}

@test "pr_json_env_block_image_sha returns the LAST matching comment's sha when the agent re-diagnosed" {
    run pr_json_env_block_image_sha '{"comments":[{"body":"first\n<!-- orchestrator:env-block image-sha=abc1234 -->"},{"body":"unrelated"},{"body":"second\n<!-- orchestrator:env-block image-sha=def5678 -->"}]}'
    [ "${status}" -eq 0 ]
    [ "${output}" = "def5678" ]
}

@test "pr_json_env_block_image_sha fails when no comment carries the marker" {
    run pr_json_env_block_image_sha '{"comments":[{"body":"a normal blocked comment with no marker"}]}'
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

@test "pr_json_env_block_image_sha fails on an empty comments array" {
    run pr_json_env_block_image_sha '{"comments":[]}'
    [ "${status}" -ne 0 ]
}

@test "current_agent_image_sha extracts IMAGE_SHA_DEVELOPMENT_AGENT from podman inspect output" {
    # shellcheck disable=SC2016
    make_stub podman 'printf "PATH=/usr/bin\nIMAGE_SHA_DEVELOPMENT_AGENT=deadbeef\nHOME=/root\n"'
    run current_agent_image_sha
    [ "${status}" -eq 0 ]
    [ "${output}" = "deadbeef" ]
}

@test "current_agent_image_sha fails when the image has no IMAGE_SHA_DEVELOPMENT_AGENT env var" {
    make_stub podman 'printf "PATH=/usr/bin\nHOME=/root\n"'
    run current_agent_image_sha
    [ "${status}" -ne 0 ]
}

@test "current_agent_image_sha fails when podman inspect itself fails" {
    make_stub podman 'exit 1'
    run current_agent_image_sha
    [ "${status}" -ne 0 ]
}

@test "try_auto_unblock_env_diagnosed_pr does nothing when the PR has no environment-block marker" {
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"a design question, not an environment issue"}]}'
    [ "${status}" -ne 0 ]
    [ ! -f "${GH_CALL_LOG}" ]
}

@test "try_auto_unblock_env_diagnosed_pr does nothing when the image sha has not changed" {
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=abc1234\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -ne 0 ]
    [ ! -f "${GH_CALL_LOG}" ]
}

@test "try_auto_unblock_env_diagnosed_pr clears Blocked and comments when a newer image has been built" {
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -eq 0 ]
    grep -q 'pr edit 5 --repo org/repo --remove-label Blocked' "${GH_CALL_LOG}"
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_5.env-unblocks")" = "1" ]
}

@test "try_auto_unblock_env_diagnosed_pr stops auto-clearing once MAX_PR_ENV_AUTO_UNBLOCKS is reached and notifies once" {
    save_env_unblock_attempts 5 "${MAX_PR_ENV_AUTO_UNBLOCKS}"
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'

    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -ne 0 ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    [[ "$(cat "${GH_CALL_LOG}")" != *"remove-label Blocked"* ]]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.env-unblock-cap-notified" ]

    # A second tick while still capped must not post the notice again (no new gh calls).
    : > "${GH_CALL_LOG}"
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -ne 0 ]
    [ ! -s "${GH_CALL_LOG}" ]
}

@test "reset_env_unblock_attempts clears both the attempts counter and the cap-notice marker" {
    save_env_unblock_attempts 5 2
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_5.env-unblock-cap-notified"
    reset_env_unblock_attempts 5
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.env-unblocks" ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.env-unblock-cap-notified" ]
    load_env_unblock_attempts 5
    [ "${ENV_UNBLOCK_ATTEMPTS}" -eq 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and false otherwise" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"}}'
    [ "${status}" -eq 0 ]
    run pr_json_is_terminal '{"autoMergeRequest":null}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and the only required check is COMPLETED/SUCCESS" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and a required check is still IN_PROGRESS" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when auto-merge is enabled but a required CheckRun has FAILED" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is false when auto-merge is enabled but a required CheckRun concluded unsuccessfully without FAILURE (#1432)" {
    local conclusion
    for conclusion in CANCELLED TIMED_OUT ACTION_REQUIRED STALE STARTUP_FAILURE; do
        run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"'"${conclusion}"'","isRequired":true}]}'
        [[ "${status}" -ne 0 ]] || { echo "terminal despite ${conclusion}"; return 1; }
    done
}

@test "pr_json_is_terminal is true when auto-merge is enabled and a required CheckRun concluded NEUTRAL or SKIPPED (#1432)" {
    local conclusion
    for conclusion in NEUTRAL SKIPPED; do
        run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"'"${conclusion}"'","isRequired":true}]}'
        [[ "${status}" -eq 0 ]] || { echo "not terminal for ${conclusion}"; return 1; }
    done
}

@test "pr_json_is_terminal is false when every required check on an auto-merge-armed PR was CANCELLED (#1432)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","statusCheckRollup":[{"name":"lint","workflowName":"PR","status":"COMPLETED","conclusion":"CANCELLED","isRequired":true},{"name":"build","workflowName":"PR","status":"COMPLETED","conclusion":"CANCELLED","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when a CANCELLED required run was superseded by a newer SUCCESS run (#1432)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"CANCELLED","isRequired":true,"startedAt":"2026-10-01T10:00:00Z"},{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"startedAt":"2026-10-01T11:00:00Z"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and only a non-required check has FAILED" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE","isRequired":false}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when auto-merge is enabled but a required legacy StatusContext has state FAILURE" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"legacy","state":"FAILURE","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and a required legacy StatusContext has state SUCCESS" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"legacy","state":"SUCCESS","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when auto-merge is enabled but reviewDecision is CHANGES_REQUESTED (#1083)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"CHANGES_REQUESTED"}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and reviewDecision is APPROVED or absent (#1083)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"APPROVED"}'
    [ "${status}" -eq 0 ]
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"}}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when isDraft is true even if autoMergeRequest is set" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"isDraft":true}'
    [ "${status}" -ne 0 ]
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"isDraft":false}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled, mergeStateStatus is BLOCKED, and statusCheckRollup is empty (#1266)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when autoMergeRequest is null and review_pipeline_finished is omitted or false (#1479)" {
    run pr_json_is_terminal '{"autoMergeRequest":null}'
    [ "${status}" -ne 0 ]
    run pr_json_is_terminal '{"autoMergeRequest":null}' false
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when autoMergeRequest is null but review_pipeline_finished is true (#1479)" {
    run pr_json_is_terminal '{"autoMergeRequest":null}' true
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal with review_pipeline_finished true still requires no CHANGES_REQUESTED (#1479)" {
    run pr_json_is_terminal '{"autoMergeRequest":null,"reviewDecision":"CHANGES_REQUESTED"}' true
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal with review_pipeline_finished true still requires no failed required check (#1479)" {
    run pr_json_is_terminal '{"autoMergeRequest":null,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}' true
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal with review_pipeline_finished true still requires not draft (#1479)" {
    run pr_json_is_terminal '{"autoMergeRequest":null,"isDraft":true}' true
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal ignores review_pipeline_finished when autoMergeRequest is already set (#1479)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"}}' false
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment is false when there are no comments (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[]}' '["credfeto"]' ""
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_unaddressed_trusted_comment is true for any trusted comment when last_seen_timestamp is empty (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"}]}' '["credfeto"]' ""
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment is false when every trusted comment is at or before last_seen_timestamp (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_unaddressed_trusted_comment is true when a trusted comment is newer than last_seen_timestamp (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment ignores comments from untrusted logins (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"random-passerby"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_unaddressed_trusted_comment treats every commenter as trusted when trusted_logins is null (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"random-passerby"},"updatedAt":"2026-08-12T10:05:07Z"}]}' 'null' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 0 ]
}

@test "pr_json_latest_trusted_comment_timestamp returns empty string when there are no trusted comments (#1307)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"random-passerby"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "pr_json_latest_trusted_comment_timestamp returns the newest trusted comment's timestamp (#1307)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"},{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp picks up a trusted review even with no top-level comments (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[],"reviews":[{"author":{"login":"credfeto"},"state":"COMMENTED","submittedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp picks up a trusted inline review comment via the third argument (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[],"reviews":[]}' '["credfeto"]' '[{"user":{"login":"credfeto"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp ignores an untrusted review and inline comment (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[],"reviews":[{"author":{"login":"random-passerby"},"submittedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' '[{"user":{"login":"random-passerby"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "pr_json_latest_trusted_comment_timestamp returns the newest across all three trusted-activity sources (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T06:00:00Z"}],"reviews":[{"author":{"login":"credfeto"},"submittedAt":"2026-08-12T07:00:00Z"}]}' '["credfeto"]' '[{"user":{"login":"credfeto"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_has_unaddressed_trusted_comment is true for a trusted review with no top-level comments (#1307 review)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[],"reviews":[{"author":{"login":"credfeto"},"submittedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment is true for a trusted inline review comment via the fourth argument (#1307 review)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[],"reviews":[]}' '["credfeto"]' "2026-08-12T07:26:12Z" '[{"user":{"login":"credfeto"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
}

@test "pr_json_latest_trusted_comment_timestamp picks up an edited top-level comment's updated_at via the fourth argument, unlike pr_json.comments alone (#1309)" {
    # gh CLI's --json comments never actually populates updatedAt, so a human's edit to an
    # already-seen comment is invisible to pr_json.comments (createdAt never advances). The REST
    # issue-comments source (fourth argument) carries the edit's real updated_at instead.
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-08-12T07:26:12Z"}],"reviews":[]}' '["credfeto"]' '[]' '[{"user":{"login":"credfeto"},"created_at":"2026-08-12T07:26:12Z","updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp ignores an untrusted issue comment via the fourth argument (#1309)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[],"reviews":[]}' '["credfeto"]' '[]' '[{"user":{"login":"random-passerby"},"created_at":"2026-08-12T07:26:12Z","updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "pr_json_latest_trusted_comment_timestamp returns the newest across all four trusted-activity sources (#1309)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T06:00:00Z"}],"reviews":[{"author":{"login":"credfeto"},"submittedAt":"2026-08-12T07:00:00Z"}]}' '["credfeto"]' '[{"user":{"login":"credfeto"},"updated_at":"2026-08-12T08:00:00Z"}]' '[{"user":{"login":"credfeto"},"created_at":"2026-08-12T07:26:12Z","updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_has_unaddressed_trusted_comment is true for an edited top-level comment detected via the fifth argument (#1309)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-08-12T07:26:12Z"}],"reviews":[]}' '["credfeto"]' "2026-08-12T07:26:12Z" '[]' '[{"user":{"login":"credfeto"},"created_at":"2026-08-12T07:26:12Z","updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment ignores automated SARIF and Super-linter summary comments (#1660)" {
    local pr='{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-10-20T07:00:00Z","body":"<!-- sarif-summary build -->\n| Rule | Count |"},{"author":{"login":"credfeto"},"updatedAt":"2026-10-20T07:05:00Z","body":"  <!-- super-linter-summary-comment -->\nAll linters passed"}],"reviews":[]}'
    run pr_json_has_unaddressed_trusted_comment "${pr}" '["credfeto"]' ""
    [ "${status}" -eq 1 ]
    run pr_json_has_unaddressed_trusted_comment '{"comments":[],"reviews":[]}' '["credfeto"]' "" '[]' '[{"user":{"login":"credfeto"},"created_at":"2026-10-20T07:00:00Z","updated_at":"2026-10-20T07:10:00Z","body":"<!-- sarif-summary -->"}]'
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_unaddressed_trusted_comment still counts a human comment next to a summary comment, or one that merely mentions a marker (#1660)" {
    local pr='{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-10-20T07:00:00Z","body":"<!-- sarif-summary -->"},{"author":{"login":"credfeto"},"updatedAt":"2026-10-20T07:05:00Z","body":"please fix the warning"}],"reviews":[]}'
    run pr_json_has_unaddressed_trusted_comment "${pr}" '["credfeto"]' ""
    [ "${status}" -eq 0 ]
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-10-20T07:05:00Z","body":"why did <!-- sarif-summary --> report this?"}],"reviews":[]}' '["credfeto"]' ""
    [ "${status}" -eq 0 ]
}

@test "pr_json_unaddressed_trusted_comments_text omits automated summary comments (#1660)" {
    local pr='{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-10-20T07:00:00Z","body":"<!-- super-linter-summary-comment -->\nAll linters passed"},{"author":{"login":"credfeto"},"createdAt":"2026-10-20T07:05:00Z","body":"please rename this"}],"reviews":[]}'
    run pr_json_unaddressed_trusted_comments_text "${pr}" '["credfeto"]' ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"please rename this"* ]]
    [[ "${output}" != *"super-linter"* ]]
    [[ "${output}" != *"All linters passed"* ]]
}

@test "fingerprint_pr_json ignores automated summary comments but not human ones (#1660)" {
    local base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local with_summary='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-10-20T07:00:00Z","body":"<!-- sarif-summary -->\nfindings"}],"reviews":[],"statusCheckRollup":[]}'
    local with_human='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-10-20T07:00:00Z","body":"please fix"}],"reviews":[],"statusCheckRollup":[]}'
    local fp_base fp_summary fp_human
    fp_base=$(fingerprint_pr_json "${base}" '["credfeto"]')
    fp_summary=$(fingerprint_pr_json "${with_summary}" '["credfeto"]')
    fp_human=$(fingerprint_pr_json "${with_human}" '["credfeto"]')
    [ -n "${fp_base}" ]
    [ "${fp_base}" = "${fp_summary}" ]
    [ "${fp_base}" != "${fp_human}" ]
}

@test "pr_json_has_unaddressed_review_request is true for reviewDecision CHANGES_REQUESTED (#1083)" {
    run pr_json_has_unaddressed_review_request '{"reviewDecision":"CHANGES_REQUESTED"}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_needs_review_approval is true for reviewDecision REVIEW_REQUIRED (#1278)" {
    run pr_json_needs_review_approval '{"reviewDecision":"REVIEW_REQUIRED"}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_needs_review_approval is false for reviewDecision APPROVED, CHANGES_REQUESTED, or absent (#1278)" {
    run pr_json_needs_review_approval '{"reviewDecision":"APPROVED"}'
    [ "${status}" -ne 0 ]
    run pr_json_needs_review_approval '{"reviewDecision":"CHANGES_REQUESTED"}'
    [ "${status}" -ne 0 ]
    run pr_json_needs_review_approval '{}'
    [ "${status}" -ne 0 ]
}

# --- apply_blocked_label (#1092) ----------------------------------------------

@test "apply_blocked_label returns 0 when the label is confirmed present on first try (#1092)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    run apply_blocked_label "PullRequest" 5 "org/repo"
    [ "${status}" -eq 0 ]
}

@test "apply_blocked_label self-heals by creating the label then retries (#1092)" {
    # First view (before any create attempt) reports false; after "label create" runs, report true.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in
        *"label create"*) printf "created\n" >> "'"${TEST_TMP}"'/created"; exit 0 ;;
        *"--json labels"*) if [ -f "'"${TEST_TMP}"'/created" ]; then printf "true\n"; else printf "false\n"; fi ;;
    esac
    exit 0'
    run apply_blocked_label "PullRequest" 5 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/created" ]
}

@test "apply_blocked_label returns 1 without dying when the label never verifies as present (#1092)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    run apply_blocked_label "PullRequest" 5 "org/repo"
    [ "${status}" -ne 0 ]
}

@test "apply_blocked_label uses the issue noun for Issue items (#1092)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    run apply_blocked_label "Issue" 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -qx 'issue edit 5 --repo org/repo --add-label Blocked' "${call_log}"
}

@test "block_pr_for_idle_exhausted_failure does not post a comment when the label cannot be verified (#1092)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s\n' "$1" "$2" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'pr comment 5' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -qx 'notified PullRequest #5' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_failure posts the comment once the label is verified present (#1092)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s\n' "$1" "$2" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q 'pr comment 5' "${call_log}"
    grep -qx 'notified PullRequest #5' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_failure marks forgiveness immediately once the label is verified present, so an unblock before any later tick still resets the budget (#1429)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_IDLE_INVOCATIONS}" "${MAX_PR_IDLE_INVOCATIONS}"

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "block_pr_for_idle_exhausted_failure does not mark forgiveness when the label cannot be verified (#1429)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_IDLE_INVOCATIONS}" "${MAX_PR_IDLE_INVOCATIONS}"

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -ne 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "block_pr_for_idle_exhausted_review does not post a comment when the label cannot be verified (#1140 review)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_review 5 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'pr comment 5' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -q 'notified PullRequest #5 reason=This PR has an unaddressed review requesting changes' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_review posts the review-specific reason once the label is verified present (#1140 review)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_review 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q 'pr comment 5 --repo org/repo --body This PR has an unaddressed review requesting changes' "${call_log}"
    grep -q 'notified PullRequest #5 reason=This PR has an unaddressed review requesting changes' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_review marks forgiveness immediately once the label is verified present, so an unblock before any later tick still resets the budget (#1429)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_IDLE_INVOCATIONS}" "${MAX_PR_IDLE_INVOCATIONS}"

    run block_pr_for_idle_exhausted_review 5 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "block_pr_for_idle_exhausted_review does not mark forgiveness when the label cannot be verified (#1429)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_IDLE_INVOCATIONS}" "${MAX_PR_IDLE_INVOCATIONS}"

    run block_pr_for_idle_exhausted_review 5 "org/repo"
    [ "${status}" -ne 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "block_pr_for_idle_exhausted_failure includes the last session's diagnostic in the Blocked comment when one was recorded (#1448)" {
    save_last_diagnostic "PullRequest" "5" "- Bash: gh pr view 5"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "Last session's diagnostic:" "${call_log}"
    grep -q -- '- Bash: gh pr view 5' "${call_log}"
}

@test "block_pr_for_idle_exhausted_failure produces the existing generic-only reason when no diagnostic was recorded (#1448)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -eq 0 ]
    run grep -q "Last session's diagnostic:" "${call_log}"
    [ "${status}" -ne 0 ]
}

@test "block_pr_for_idle_exhausted_review includes the last session's diagnostic in the Blocked comment when one was recorded (#1448)" {
    save_last_diagnostic "PullRequest" "5" "- Bash: gh pr view 5"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }

    run block_pr_for_idle_exhausted_review 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "Last session's diagnostic:" "${call_log}"
}

# --- block_pr_for_idle_exhausted_no_progress (#1463) -----------------------------

@test "block_pr_for_idle_exhausted_no_progress does not post a comment when the label cannot be verified (#1463)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'pr comment 5' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -q 'notified PullRequest #5 reason=This PR.s automation idle-invocation budget' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_no_progress posts the no-known-blocking-reason text once the label is verified present (#1463)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "pr comment 5 --repo org/repo --body This PR's automation idle-invocation budget" "${call_log}"
    grep -q "notified PullRequest #5 reason=This PR.s automation idle-invocation budget" "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_no_progress says a failed required check could not be ruled out when the required-check lookup failed (#1557)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { return 0; }

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo" "true"
    [ "${status}" -eq 0 ]
    grep -q "the lookup of which checks are required failed, so a failed required check could not be ruled out" "${call_log}"
    run grep -c "no required check has failed" "${call_log}"
    [ "${output}" = "0" ]
}

@test "block_pr_for_idle_exhausted_no_progress marks forgiveness immediately once the label is verified present, so an unblock before any later tick still resets the budget (#1463)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_IDLE_INVOCATIONS}" "${MAX_PR_IDLE_INVOCATIONS}"

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "block_pr_for_idle_exhausted_no_progress does not mark forgiveness when the label cannot be verified (#1463)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_IDLE_INVOCATIONS}" "${MAX_PR_IDLE_INVOCATIONS}"

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo"
    [ "${status}" -ne 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "block_pr_for_idle_exhausted_no_progress includes the last session's diagnostic in the Blocked comment when one was recorded (#1463)" {
    save_last_diagnostic "PullRequest" "5" "- Bash: gh pr view 5"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "Last session's diagnostic:" "${call_log}"
}

@test "block_pr_for_idle_exhausted_no_progress gives the board status and the next phase due when there is a board (#1650)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    _WF_PROJECT_ID="PVT_test"
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'AI Security Review'; }

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo" "false" '{"statusCheckRollup":[]}'
    [ "${status}" -eq 0 ]
    grep -q "Blocking this PR until a human investigates. Board status: AI Security Review; next phase due: PHASE F (security review)." "${call_log}"
}

@test "block_pr_for_idle_exhausted_no_progress says no phase is due when the board status names none (#1650)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    _WF_PROJECT_ID="PVT_test"
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item() { printf 'Complete'; }

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo" "false" '{"statusCheckRollup":[]}'
    [ "${status}" -eq 0 ]
    grep -q "Board status: Complete; next phase due: none (the board status names no phase)." "${call_log}"
}

@test "block_pr_for_idle_exhausted_no_progress leaves the board out when there is no board (#1650)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    _WF_PROJECT_ID=""
    board_substatus_for_item() { printf 'AI Review'; }

    run block_pr_for_idle_exhausted_no_progress 5 "org/repo" "false" '{"statusCheckRollup":[]}'
    [ "${status}" -eq 0 ]
    grep -q "pr comment 5 --repo org/repo --body This PR's automation idle-invocation budget" "${call_log}"
    run grep -c "Board status:" "${call_log}"
    [ "${output}" = "0" ]
}

# --- apply_blocked_label_with_reason (#1140 review) -----------------------------

@test "apply_blocked_label_with_reason posts the reason as a comment and notifies with it on success" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run apply_blocked_label_with_reason "Issue" 42 "org/repo" "custom reason text"
    [ "${status}" -eq 0 ]
    grep -q "issue comment 42 --repo org/repo --body custom reason text" "${call_log}"
    grep -qx "type=Issue id=42 reason=custom reason text" "${_notif_log}"
}

@test "apply_blocked_label_with_reason still notifies but skips the comment when the label cannot be verified" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run apply_blocked_label_with_reason "PullRequest" 5 "org/repo" "unverifiable reason"
    [ "${status}" -ne 0 ]
    run grep -q 'comment 5' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -qx "type=PullRequest id=5 reason=unverifiable reason" "${_notif_log}"
}

@test "apply_blocked_label_with_reason still notifies and returns success when the label verifies but the comment call itself fails (#1140 review)" {
    # The label is confirmed present, but the "gh ... comment" invocation fails (e.g. a transient
    # API error) — the 2>/dev/null || true swallows that failure, so the function must still
    # report the label's own success and must still fire the Discord notification with the reason.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in
        *"--json labels"*) printf "true\n" ;;
        *"comment"*) exit 1 ;;
    esac
    exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run apply_blocked_label_with_reason "Issue" 42 "org/repo" "custom reason text"
    [ "${status}" -eq 0 ]
    grep -qx "type=Issue id=42 reason=custom reason text" "${_notif_log}"
}

@test "apply_blocked_label_with_reason marks forgiveness immediately once the label is verified present, for any caller (#1429 review)" {
    # Forgiveness-marking moved from a per-caller opt-in into apply_blocked_label_with_reason
    # itself, so this exercises the primitive directly rather than through any specific block_*
    # wrapper - every blocking path gets this for free, not just the idle-exhaustion callers.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0

    run apply_blocked_label_with_reason "PullRequest" 5 "org/repo" "any reason"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "apply_blocked_label_with_reason does not mark forgiveness when the label cannot be verified (#1429 review)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0

    run apply_blocked_label_with_reason "PullRequest" 5 "org/repo" "any reason"
    [ "${status}" -ne 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

# --- block_issue_for_unapplied_plan_approval (#1286) --------------------------

@test "block_issue_for_unapplied_plan_approval posts the self-heal reason once the label is verified present" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s\n' "$1" "$2" >> "${TEST_TMP}/discord_calls"; }

    run block_issue_for_unapplied_plan_approval 99 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "issue comment 99 --repo org/repo --body This issue has a posted Implementation Plan" "${call_log}"
    grep -qx "notified Issue #99" "${TEST_TMP}/discord_calls"
}

@test "block_issue_for_unapplied_plan_approval also marks forgiveness once the label is verified present, closing the gap centralising left open before (#1429 review)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0

    run block_issue_for_unapplied_plan_approval 99 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

# --- sync_pr_labels_from_linked_issues (#1321) --------------------------------

@test "sync_pr_labels_from_linked_issues never copies Blocked or On-Hold, but still copies other labels" {
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"
    case "$*" in
        *"pr view 42 --repo org/repo --json closingIssuesReferences"*) printf "164\n" ;;
        *"issue view 164 --repo org/repo --json labels"*) printf "Bug\nBlocked\nOn-Hold\n" ;;
        *"pr edit"*) exit 0 ;;
    esac'

    sync_pr_labels_from_linked_issues 42 '{"labels":[]}'

    grep -q -- "pr edit 42 --repo org/repo --add-label Bug" "${call_log}"
    run grep -- "--add-label Blocked" "${call_log}"
    [ "${status}" -ne 0 ]
    run grep -- "--add-label On-Hold" "${call_log}"
    [ "${status}" -ne 0 ]
}

@test "sync_pr_labels_from_linked_issues does not call gh pr edit when there is nothing new to add" {
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"
    case "$*" in
        *"pr view 42 --repo org/repo --json closingIssuesReferences"*) printf "164\n" ;;
        *"issue view 164 --repo org/repo --json labels"*) printf "Blocked\nOn-Hold\n" ;;
        *"pr edit"*) exit 0 ;;
    esac'

    sync_pr_labels_from_linked_issues 42 '{"labels":[]}'

    run grep -- "pr edit" "${call_log}"
    [ "${status}" -ne 0 ]
}

# --- block_pr_for_ci_timeout (#1140 review) --------------------------------------

@test "block_pr_for_ci_timeout posts the timeout-specific reason and clears the pending-CI state once the label is verified (#1140 review)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }
    CI_CHECK_TIMEOUT_MINUTES=60
    save_pr_head_oid 5 "abc123" "$(date +%s)"

    run block_pr_for_ci_timeout 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "pr comment 5 --repo org/repo --body CI checks have been pending for over 60 minutes" "${call_log}"
    grep -q 'notified PullRequest #5 reason=CI checks have been pending for over 60 minutes' "${_notif_log}"
    [ ! -f "$(pr_head_oid_file_path 5)" ]
}

@test "block_pr_for_ci_timeout now also marks forgiveness once the label is verified present, closing the gap centralising left open before (#1429 review)" {
    # block_pr_for_ci_timeout used to be one of the blocking paths that never opted into
    # forgiveness-marking, so a human unblocking a CI-timeout-capped PR before a later tick
    # observed it still Blocked got no fresh budget. Confirms that gap is now closed.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    CI_CHECK_TIMEOUT_MINUTES=60
    save_pr_head_oid 5 "abc123" "$(date +%s)"

    run block_pr_for_ci_timeout 5 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "block_pr_for_ci_timeout leaves the pending-CI state alone when the label cannot be verified (#1140 review)" {
    # If escalation itself failed, the timeout clock must NOT be cleared — otherwise the next
    # tick silently re-arms a fresh full-length wait instead of re-attempting the escalation.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    CI_CHECK_TIMEOUT_MINUTES=60
    save_pr_head_oid 5 "abc123" "$(date +%s)"

    run block_pr_for_ci_timeout 5 "org/repo"
    [ "${status}" -ne 0 ]
    [ -f "$(pr_head_oid_file_path 5)" ]
}

@test "pr_json_has_unaddressed_review_request is false for reviewDecision APPROVED, REVIEW_REQUIRED, or absent (#1083)" {
    run pr_json_has_unaddressed_review_request '{"reviewDecision":"APPROVED"}'
    [ "${status}" -ne 0 ]
    run pr_json_has_unaddressed_review_request '{"reviewDecision":"REVIEW_REQUIRED"}'
    [ "${status}" -ne 0 ]
    run pr_json_has_unaddressed_review_request '{}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is true for a required CheckRun with conclusion FAILURE" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is true for a required CheckRun with conclusion CANCELLED or TIMED_OUT (#1432)" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"CANCELLED","isRequired":true}]}'
    [ "${status}" -eq 0 ]
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"TIMED_OUT","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is false for a required CheckRun with conclusion NEUTRAL, SKIPPED or none yet (#1432)" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"NEUTRAL","isRequired":true},{"name":"lint","status":"COMPLETED","conclusion":"SKIPPED","isRequired":true},{"name":"build","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_failed_check_of_unknown_requiredness is true for a CANCELLED check whose required-ness is unknown (#1432)" {
    run pr_json_has_failed_check_of_unknown_requiredness '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"CANCELLED"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is false for a non-required CheckRun with conclusion FAILURE" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE","isRequired":false}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is false when all required checks are SUCCESS or pending" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true},{"name":"lint","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is true for a required legacy StatusContext with state FAILURE" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is true for a required legacy StatusContext with state ERROR" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"ERROR","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is false for a required legacy StatusContext with state SUCCESS or PENDING" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"SUCCESS","isRequired":true}]}'
    [ "${status}" -ne 0 ]
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"PENDING","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is false when statusCheckRollup is empty or absent" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[]}'
    [ "${status}" -ne 0 ]
    run pr_json_has_failed_required_check '{}'
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged parks a terminal (auto-merge enabled) PR" {
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}'
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged advances a PR with auto-merge enabled but a failed required check" {
    save_pr_invocation_counts 42 4 2
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_should_advance_unchanged advances a non-terminal PR within the idle budget" {
    save_pr_invocation_counts 42 4 2
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":null}'
    [ "${status}" -eq 0 ]
}

@test "pr_should_advance_unchanged parks a non-terminal PR once the idle budget is exhausted" {
    save_pr_invocation_counts 42 10 "${MAX_PR_IDLE_INVOCATIONS}"
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":null}'
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged advances a terminal PR within the idle budget when has_unaddressed_comment is true (#1307 review)" {
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}' "true"
    [ "${status}" -eq 0 ]
}

@test "pr_should_advance_unchanged still parks a terminal PR when has_unaddressed_comment is false (#1307 review)" {
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}' "false"
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged parks a terminal PR with has_unaddressed_comment true once the idle budget is exhausted (#1307 review)" {
    # The escalation-defeating regression this guards against: an unaddressed comment must not
    # exempt a PR from the idle budget forever, or the failed-check/unaddressed-review-request
    # escalation in oneshot's caller never gets a real chance to fire.
    save_pr_invocation_counts 42 10 "${MAX_PR_IDLE_INVOCATIONS}"
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}' "true"
    [ "${status}" -ne 0 ]
}

# --- issue_should_advance_unchanged / block_issue_for_idle_exhausted_no_progress (#1264) ---
# has_plan_comment is "true" throughout this block: this predates the third (never-planned) state,
# so every one of its scenarios is a plan that was posted (approved or not); the not-approved case
# is "posted but not approved," never "posted at all." The argument became mandatory, so these now
# say what they always meant explicitly.

@test "issue_should_advance_unchanged is false when the plan is not approved, regardless of idle count" {
    run issue_should_advance_unchanged 99 "false" "true"
    [ "${status}" -ne 0 ]
}

@test "issue_should_advance_unchanged is true when the plan is approved and idle count is below budget" {
    save_issue_invocation_counts 99 4 2
    run issue_should_advance_unchanged 99 "true" "true"
    [ "${status}" -eq 0 ]
}

@test "issue_should_advance_unchanged is false when the plan is approved but the idle budget is exhausted" {
    save_issue_invocation_counts 99 10 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    run issue_should_advance_unchanged 99 "true" "true"
    [ "${status}" -ne 0 ]
}

@test "issue_should_advance_unchanged is true for a fresh Issue (no guard file) that is plan-approved" {
    run issue_should_advance_unchanged 99 "true" "true"
    [ "${status}" -eq 0 ]
}

@test "block_issue_for_idle_exhausted_no_progress does not post a comment when the label cannot be verified" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_issue_for_idle_exhausted_no_progress 99 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'issue comment 99' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -q 'notified Issue #99 reason=This issue.s plan is approved' "${TEST_TMP}/discord_calls"
}

@test "block_issue_for_idle_exhausted_no_progress posts the reason once the label is verified present" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_issue_for_idle_exhausted_no_progress 99 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "issue comment 99 --repo org/repo --body This issue's plan is approved" "${call_log}"
    grep -q "notified Issue #99 reason=This issue.s plan is approved" "${TEST_TMP}/discord_calls"
}

@test "block_issue_for_idle_exhausted_no_progress marks forgiveness immediately once the label is verified present, so an unblock before any later tick still resets the budget (#1429)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_issue_invocation_counts 99 "${MAX_ISSUE_IDLE_INVOCATIONS}" "${MAX_ISSUE_IDLE_INVOCATIONS}"

    run block_issue_for_idle_exhausted_no_progress 99 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "block_issue_for_idle_exhausted_no_progress does not mark forgiveness when the label cannot be verified (#1429)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_issue_invocation_counts 99 "${MAX_ISSUE_IDLE_INVOCATIONS}" "${MAX_ISSUE_IDLE_INVOCATIONS}"

    run block_issue_for_idle_exhausted_no_progress 99 "org/repo"
    [ "${status}" -ne 0 ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "block_issue_for_idle_exhausted_no_progress includes the last session's diagnostic in the Blocked comment when one was recorded (#1448)" {
    save_last_diagnostic "Issue" "99" "- Bash: gh issue view 99"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }

    run block_issue_for_idle_exhausted_no_progress 99 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "Last session's diagnostic:" "${call_log}"
}

# --- issue_should_advance_unchanged / block_issue_for_idle_exhausted_no_plan (#1427) ---
# The plan-posted-not-approved case is already covered above ("... is false when the plan is not
# approved, regardless of idle count") with the same has_plan_comment="true": that test already
# exercises exactly this combination, so it is not repeated here.

@test "issue_should_advance_unchanged is true when no plan was ever posted and idle count is below budget" {
    save_issue_invocation_counts 99 4 2
    run issue_should_advance_unchanged 99 "false" "false"
    [ "${status}" -eq 0 ]
}

@test "issue_should_advance_unchanged is false when no plan was ever posted but the idle budget is exhausted" {
    save_issue_invocation_counts 99 10 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    run issue_should_advance_unchanged 99 "false" "false"
    [ "${status}" -ne 0 ]
}

@test "issue_should_advance_unchanged is true for a fresh Issue (no guard file) with no plan posted" {
    run issue_should_advance_unchanged 99 "false" "false"
    [ "${status}" -eq 0 ]
}

@test "block_issue_for_idle_exhausted_no_plan does not post a comment when the label cannot be verified" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_issue_for_idle_exhausted_no_plan 99 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'issue comment 99' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -q 'notified Issue #99 reason=This issue was re-invoked' "${TEST_TMP}/discord_calls"
}

@test "block_issue_for_idle_exhausted_no_plan posts the reason once the label is verified present" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_issue_for_idle_exhausted_no_plan 99 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "issue comment 99 --repo org/repo --body This issue was re-invoked ${MAX_ISSUE_IDLE_INVOCATIONS} times" "${call_log}"
    grep -q "notified Issue #99 reason=This issue was re-invoked" "${TEST_TMP}/discord_calls"
}

@test "block_issue_for_idle_exhausted_no_plan marks forgiveness immediately once the label is verified present, so an unblock before any later tick still resets the budget" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_issue_invocation_counts 99 "${MAX_ISSUE_IDLE_INVOCATIONS}" "${MAX_ISSUE_IDLE_INVOCATIONS}"

    run block_issue_for_idle_exhausted_no_plan 99 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "block_issue_for_idle_exhausted_no_plan does not mark forgiveness when the label cannot be verified" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    save_issue_invocation_counts 99 "${MAX_ISSUE_IDLE_INVOCATIONS}" "${MAX_ISSUE_IDLE_INVOCATIONS}"

    run block_issue_for_idle_exhausted_no_plan 99 "org/repo"
    [ "${status}" -ne 0 ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "block_issue_for_idle_exhausted_no_plan includes the last session's diagnostic in the Blocked comment when one was recorded (#1448)" {
    save_last_diagnostic "Issue" "99" "- Bash: gh issue view 99"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }

    run block_issue_for_idle_exhausted_no_plan 99 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "Last session's diagnostic:" "${call_log}"
}
