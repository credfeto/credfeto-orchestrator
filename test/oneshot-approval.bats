#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- plan-awaiting-human-approval detection (#1286) -------------------------

@test "issue_json_has_plan_comment detects the heading case-insensitively and is false when absent" {
    run issue_json_has_plan_comment '{"comments":[{"body":"## implementation plan\n\nstuff"}]}'
    [ "${status}" -eq 0 ]

    run issue_json_has_plan_comment '{"comments":[{"body":"just chatting"}]}'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is true for a trusted human approval comment posted after the plan" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"credfeto"},"authorAssociation":"OWNER","body":"approved"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "issue_json_has_human_plan_approval is false when only the bot's OWN comment matches the approval keyword (#434, #615 regression)" {
    # Live-verified: funfair-build-check#434's only "approved"-matching comment was the bot's own,
    # explaining that approval was NOT found. The pre-#1286 matcher (no author restriction) read
    # this as approved.
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"bot"},"body":"I cannot treat it as approved yet: the board status is Todo, not Approved."}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is false when the approving author is not in the trusted logins list" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"randomer"},"body":"lgtm"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is false when the approval comment precedes the plan comment" {
    local issue='{"comments":[{"author":{"login":"credfeto"},"body":"looks good"},{"author":{"login":"bot"},"body":"## Implementation Plan\n..."}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is false when there is no plan comment at all" {
    local issue='{"comments":[{"author":{"login":"credfeto"},"body":"approved"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_plan_awaiting_human_approval is true for a plan comment with no human approval since (#1232-shaped)" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n### Open questions\nNone, ready to proceed pending approval."}]}'
    run issue_plan_awaiting_human_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "issue_plan_awaiting_human_approval is false once a trusted human approves" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"credfeto"},"authorAssociation":"OWNER","body":"lgtm"}]}'
    run issue_plan_awaiting_human_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_plan_awaiting_human_approval is false when there is no plan comment at all (key negative case, #3613-shaped)" {
    # funfair-ethereum-proxy-server-monitor#3613: a tracking issue whose own open questions live on
    # sub-issues, not itself — must never be flagged just because it has comments.
    local issue='{"comments":[{"author":{"login":"bot"},"body":"Status update. Sub-issue status: ..."}]}'
    run issue_plan_awaiting_human_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "the plan-approval patterns in lib/globals are identical to cfwf's, which issue plan-status --approval applies (#1772)" {
    local name cfwf_line lib_line cfwf="${BATS_TEST_DIRNAME}/../containers/base/development-full/scripts/cfwf"
    for name in LOOSE_PLAN_HEADING_PATTERN APPROVAL_LINE_KEYWORD_PATTERN APPROVAL_NEGATION_PATTERN APPROVER_ASSOCIATIONS; do
        cfwf_line=$(grep -E "^readonly ${name}=" "${cfwf}")
        lib_line=$(grep -E "^${name}=" "${BATS_TEST_DIRNAME}/../lib/globals")
        [ -n "${cfwf_line}" ] && [ "${cfwf_line#readonly }" = "${lib_line}" ] || { echo "${name} differs" >&2; return 1; }
    done
}

# Prints yes or no: whether issue_json_has_human_plan_approval approves an issue whose plan is by
# planner and whose one later comment has body $1, author $2 (default credfeto) and association $3
# (default OWNER), for the orchestrator login bot and the trusted logins credfeto, someone, planner,
# bot and the two trusted GitHub bots.
host_approval_of() {
    local issue
    issue=$(jq -n --arg body "$1" --arg login "${2-credfeto}" --arg association "${3:-OWNER}" \
        '{comments: [{author: {login: "planner"}, authorAssociation: "COLLABORATOR", body: "## Implementation Plan\nThe plan."},
                     {author: (if $login == "" then null else {login: $login} end), authorAssociation: $association, body: $body}]}')
    if issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto","someone","planner","bot","copilot-pull-request-reviewer","github-advanced-security[bot]"]'; then
        echo yes
    else
        echo no
    fi
}

@test "issue_json_has_human_plan_approval takes approved or lgtm on a line of its own making, from a collaborator or the owner" {
    local body
    for body in "approved" "LGTM" "Approved." "Thanks, lgtm!" "(approved)" "**approved**" "Read it."$'\n'"approved, ship it" "approved"$'\n'"No objections."; do
        [ "$(host_approval_of "${body}")" = yes ] || { echo "not approved: ${body}" >&2; return 1; }
    done
    [ "$(host_approval_of approved someone COLLABORATOR)" = yes ]
    [ "$(host_approval_of approved someone MEMBER)" = yes ]
}

@test "issue_json_has_human_plan_approval refuses what either old rule refused, negations, questions and conditions, and every author but a human collaborator (#1772)" {
    local body
    for body in "go ahead" "looks good" "_approved_" "__LGTM__" "> approved" "plan_approved" "disapproved" "not approved yet" "approved?" \
        "Is this approved?" "approved if you fix the tests" "approved once CI passes" "I don't think it is approved" "can't say lgtm" \
        "never approved" "approved - pending review" "nearly approved" "approved. No objections." ""; do
        [ "$(host_approval_of "${body}")" = no ] || { echo "approved: ${body}" >&2; return 1; }
    done
    [ "$(host_approval_of approved stranger NONE)" = no ]
    [ "$(host_approval_of approved stranger COLLABORATOR)" = no ]
    [ "$(host_approval_of approved someone CONTRIBUTOR)" = no ]
    [ "$(host_approval_of approved someone NONE)" = no ]
    [ "$(host_approval_of approved bot COLLABORATOR)" = no ]
    [ "$(host_approval_of approved planner COLLABORATOR)" = no ]
    [ "$(host_approval_of approved copilot-pull-request-reviewer NONE)" = no ]
    [ "$(host_approval_of approved "github-advanced-security[bot]" COLLABORATOR)" = no ]
    [ "$(host_approval_of approved "" NONE)" = no ]
}

@test "issue_json_has_human_plan_approval needs the approval after the latest plan, a revised one included (#1772)" {
    local issue
    issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\nfirst"},{"author":{"login":"credfeto"},"authorAssociation":"OWNER","body":"approved"},{"author":{"login":"bot"},"body":"## Implementation Plan\nrevised"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
    issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\nfirst"},{"author":{"login":"credfeto"},"authorAssociation":"OWNER","body":"approved"},{"author":{"login":"bot"},"body":"The ##implementation plan, revised"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
    issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\nfirst"},{"author":{"login":"bot"},"body":"## Implementation Plan\nrevised"},{"author":{"login":"credfeto"},"authorAssociation":"OWNER","body":"approved"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -eq 0 ]
}

# The approval jq the orchestrator used before #1772 (issue_json_has_human_plan_approval's old filter).
old_host_approval() {
    printf '%s' "$1" | jq -e --arg me "$2" --argjson trusted "$3" '
        (.comments) as $c
        | (first(range($c|length) | select($c[.].body // "" | test("##\\s*Implementation Plan";"i"))) // -1) as $i
        | if $i >= 0 then
            $c[($i+1):]
            | map(select(.author.login as $login | $login != $me and (($trusted // []) | index($login)) != null))
            | any(.[]; .body // "" | test("\\b(approved|go ahead|looks good|lgtm)\\b";"i"))
          else
            false
          end
    ' > /dev/null 2>&1
}

@test "issue_json_has_human_plan_approval never approves an issue the old check refused (#1772 regression)" {
    local body author issue trusted='["credfeto","someone","planner","bot","copilot-pull-request-reviewer"]'
    local -i refused_by_old=0 accepted_by_old=0
    for body in "approved" "lgtm" "go ahead" "_approved_" "not approved yet" "> approved" "plan_approved" "approved?" "nothing"; do
        for author in "credfeto OWNER" "someone COLLABORATOR" "stranger NONE" "bot COLLABORATOR" "planner COLLABORATOR" "copilot-pull-request-reviewer NONE"; do
            for order in after before revised; do
                issue=$(jq -n --arg body "${body}" --arg login "${author% *}" --arg association "${author#* }" --arg order "${order}" '
                    {author: {login: "planner"}, authorAssociation: "COLLABORATOR", body: "## Implementation Plan\nplan"} as $plan
                    | {author: {login: $login}, authorAssociation: $association, body: $body} as $comment
                    | {comments: (if $order == "after" then [$plan, $comment]
                                  elif $order == "before" then [$comment, $plan]
                                  else [$plan, $comment, ($plan | .body = "## Implementation Plan\nrevised")] end)}')
                if old_host_approval "${issue}" bot "${trusted}"; then
                    accepted_by_old+=1
                else
                    refused_by_old+=1
                    run issue_json_has_human_plan_approval "${issue}" bot "${trusted}"
                    [ "${status}" -ne 0 ] || { echo "old refused, new accepts: ${author} ${order}: ${body}" >&2; return 1; }
                fi
            done
        done
    done
    [ "${refused_by_old}" -gt 0 ] && [ "${accepted_by_old}" -gt 0 ]
}

@test "fingerprint_issue_json with trusted logins: trusted comment changes fingerprint" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_trusted='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"owner"},"body":"hello","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local trusted='["owner"]'
    local fp_base fp_trusted
    fp_base=$(fingerprint_issue_json "${issue_base}" "${trusted}")
    fp_trusted=$(fingerprint_issue_json "${issue_trusted}" "${trusted}")
    [ "${fp_base}" != "${fp_trusted}" ]
}

@test "fingerprint_issue_json with trusted logins: untrusted comment does not change fingerprint" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_untrusted='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"randomer"},"body":"hello","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_issue_json "${issue_base}" "${trusted}")
    fp_untrusted=$(fingerprint_issue_json "${issue_untrusted}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_issue_json without trusted logins uses all comments" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_comment='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"anyone"},"body":"hi","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local fp_base fp_with
    fp_base=$(fingerprint_issue_json "${issue_base}")
    fp_with=$(fingerprint_issue_json "${issue_comment}")
    [ "${fp_base}" != "${fp_with}" ]
}

@test "fingerprint_issue_json changes when plan_approved flips, with no other field changed (#1204)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp_unapproved fp_approved
    fp_unapproved=$(fingerprint_issue_json "${issue}" "null" "false")
    fp_approved=$(fingerprint_issue_json "${issue}" "null" "true")
    [ "${fp_unapproved}" != "${fp_approved}" ]
}

@test "fingerprint_issue_json defaults plan_approved to false when the third argument is omitted (#1204)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp_omitted fp_explicit_false
    fp_omitted=$(fingerprint_issue_json "${issue}")
    fp_explicit_false=$(fingerprint_issue_json "${issue}" "null" "false")
    [ "${fp_omitted}" = "${fp_explicit_false}" ]
}

@test "fingerprint_issue_json and fingerprint_pr_json prepend FINGERPRINT_SCHEMA_VERSION and a stale version compares unequal (#1204)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp_v1 fp_v2
    fp_v1=$(fingerprint_issue_json "${issue}")
    [[ "${fp_v1}" == "${FINGERPRINT_SCHEMA_VERSION}:"* ]]

    FINGERPRINT_SCHEMA_VERSION=$(( FINGERPRINT_SCHEMA_VERSION + 1 ))
    fp_v2=$(fingerprint_issue_json "${issue}")
    [[ "${fp_v2}" == "${FINGERPRINT_SCHEMA_VERSION}:"* ]]
    [ "${fp_v1}" != "${fp_v2}" ]

    local pr='{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_fp
    pr_fp=$(fingerprint_pr_json "${pr}")
    [[ "${pr_fp}" == "${FINGERPRINT_SCHEMA_VERSION}:"* ]]
}

@test "fingerprint_issue_json and fingerprint_pr_json return non-zero (do not hash a partial/empty stream) when jq fails on malformed input (#1102)" {
    run fingerprint_issue_json 'not valid json'
    [ "${status}" -ne 0 ]
    [[ "${output}" != "${FINGERPRINT_SCHEMA_VERSION}:"* ]]

    run fingerprint_pr_json 'not valid json'
    [ "${status}" -ne 0 ]
    [[ "${output}" != "${FINGERPRINT_SCHEMA_VERSION}:"* ]]
}

@test "fingerprint_issue_json happy-path hash is unchanged by the jq-failure-guard refactor (#1102)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp
    fp=$(fingerprint_issue_json "${issue}" "null" "false")
    [ "${fp}" = "${FINGERPRINT_SCHEMA_VERSION}:36d5acf9d9297f831145e17ec71ce45fcbd20d60b9af5b25ef6773cacbdc5116" ]
}

@test "fingerprint_pr_json with trusted logins: trusted comment changes fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_trusted='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"owner"},"body":"lgtm","updatedAt":"2024-01-01T00:00:00Z"}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_trusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_trusted=$(fingerprint_pr_json "${pr_trusted}" "${trusted}")
    [ "${fp_base}" != "${fp_trusted}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted comment does not change fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_untrusted='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"randomer"},"body":"spam","updatedAt":"2024-01-01T00:00:00Z"}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_untrusted=$(fingerprint_pr_json "${pr_untrusted}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted review changes fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"owner"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_review
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_review=$(fingerprint_pr_json "${pr_review}" "${trusted}")
    [ "${fp_base}" != "${fp_review}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted review does not change fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_untrusted_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"spammer"},"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_untrusted=$(fingerprint_pr_json "${pr_untrusted_review}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json without trusted logins uses all comments and reviews" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"anyone"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local fp_base fp_review
    fp_base=$(fingerprint_pr_json "${pr_base}")
    fp_review=$(fingerprint_pr_json "${pr_review}")
    [ "${fp_base}" != "${fp_review}" ]
}

@test "fingerprint_pr_json changes when reviewDecision flips (#1096)" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewDecision":"APPROVED"}'
    local pr_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewDecision":"REVIEW_REQUIRED"}'
    local fp_a fp_b
    fp_a=$(fingerprint_pr_json "${pr_a}")
    fp_b=$(fingerprint_pr_json "${pr_b}")
    [ "${fp_a}" != "${fp_b}" ]
}

@test "fingerprint_pr_json changes when baseRefName is retargeted (#1096)" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","baseRefName":"main","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","baseRefName":"develop","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local fp_a fp_b
    fp_a=$(fingerprint_pr_json "${pr_a}")
    fp_b=$(fingerprint_pr_json "${pr_b}")
    [ "${fp_a}" != "${fp_b}" ]
}

@test "fingerprint_pr_json changes when a reviewer is requested or removed (#1096)" {
    local pr_none='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[]}'
    local pr_requested='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[{"login":"alice"}]}'
    local fp_none fp_requested
    fp_none=$(fingerprint_pr_json "${pr_none}")
    fp_requested=$(fingerprint_pr_json "${pr_requested}")
    [ "${fp_none}" != "${fp_requested}" ]
}

@test "fingerprint_pr_json includes team review requests by slug (#1096)" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[{"slug":"team-a"}]}'
    local pr_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[{"slug":"team-b"}]}'
    local fp_a fp_b
    fp_a=$(fingerprint_pr_json "${pr_a}")
    fp_b=$(fingerprint_pr_json "${pr_b}")
    [ "${fp_a}" != "${fp_b}" ]
}

@test "fingerprint_pr_json changes when a PR is assigned (#1096)" {
    local pr_unassigned='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[]}'
    local pr_assigned='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[{"login":"bob"}]}'
    local fp_unassigned fp_assigned
    fp_unassigned=$(fingerprint_pr_json "${pr_unassigned}")
    fp_assigned=$(fingerprint_pr_json "${pr_assigned}")
    [ "${fp_unassigned}" != "${fp_assigned}" ]
}

@test "fingerprint_pr_json changes when milestone is set or changed (#1096)" {
    local pr_none='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"milestone":null}'
    local pr_v1='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"milestone":{"title":"v1"}}'
    local pr_v2='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"milestone":{"title":"v2"}}'
    local fp_none fp_v1 fp_v2
    fp_none=$(fingerprint_pr_json "${pr_none}")
    fp_v1=$(fingerprint_pr_json "${pr_v1}")
    fp_v2=$(fingerprint_pr_json "${pr_v2}")
    [ "${fp_none}" != "${fp_v1}" ]
    [ "${fp_v1}" != "${fp_v2}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted comment body edit changes fingerprint even with updatedAt null (#1095)" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"owner"},"body":"original","updatedAt":null}],"reviews":[],"statusCheckRollup":[]}'
    local pr_edited='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"owner"},"body":"edited","updatedAt":null}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_edited
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_edited=$(fingerprint_pr_json "${pr_edited}" "${trusted}")
    [ "${fp_base}" != "${fp_edited}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted review body edit changes fingerprint with same state/submittedAt (#1095)" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"owner"},"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z","body":"terse"}],"statusCheckRollup":[]}'
    local pr_edited='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"owner"},"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z","body":"full required-changes list"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_edited
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_edited=$(fingerprint_pr_json "${pr_edited}" "${trusted}")
    [ "${fp_base}" != "${fp_edited}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted comment and review body edits do not change fingerprint (#1095)" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"randomer"},"body":"original","updatedAt":null}],"reviews":[{"author":{"login":"randomer"},"state":"COMMENTED","submittedAt":"2024-01-01T00:00:00Z","body":"terse"}],"statusCheckRollup":[]}'
    local pr_edited='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"randomer"},"body":"edited","updatedAt":null}],"reviews":[{"author":{"login":"randomer"},"state":"COMMENTED","submittedAt":"2024-01-01T00:00:00Z","body":"edited too"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_edited
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_edited=$(fingerprint_pr_json "${pr_edited}" "${trusted}")
    [ "${fp_base}" = "${fp_edited}" ]
}

@test "fingerprint_pr_json is stable across runs for identical JSON regardless of comment/review array order (#1095)" {
    local pr_order_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"a"},"body":"first","updatedAt":null},{"author":{"login":"b"},"body":"second","updatedAt":null}],"reviews":[{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z","body":"lgtm"},{"author":{"login":"b"},"state":"COMMENTED","submittedAt":"2024-01-02T00:00:00Z","body":"nit"}],"statusCheckRollup":[]}'
    local pr_order_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"b"},"body":"second","updatedAt":null},{"author":{"login":"a"},"body":"first","updatedAt":null}],"reviews":[{"author":{"login":"b"},"state":"COMMENTED","submittedAt":"2024-01-02T00:00:00Z","body":"nit"},{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z","body":"lgtm"}],"statusCheckRollup":[]}'
    local fp_a fp_b fp_a_again
    fp_a=$(fingerprint_pr_json "${pr_order_a}")
    fp_b=$(fingerprint_pr_json "${pr_order_b}")
    fp_a_again=$(fingerprint_pr_json "${pr_order_a}")
    [ "${fp_a}" = "${fp_b}" ]
    [ "${fp_a}" = "${fp_a_again}" ]
}

@test "fetch_pr_json requests baseRefName, reviewDecision, reviewRequests, assignees, and milestone fields (#1096)" {
    make_stub gh 'printf "%s" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "{}"'
    fetch_pr_json 42 > /dev/null
    run cat "${TEST_TMP}/gh_args"
    [[ "${output}" == *"baseRefName"* ]]
    [[ "${output}" == *"reviewDecision"* ]]
    [[ "${output}" == *"reviewRequests"* ]]
    [[ "${output}" == *"assignees"* ]]
    [[ "${output}" == *"milestone"* ]]
}

@test "fingerprint_pr_json changes when a new inline review comment appears with no other field changed (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local rc_none='[]'
    local rc_one='[{"user":{"login":"anyone"},"body":"Why this change?","updated_at":"2024-01-01T00:00:00Z"}]'
    local fp_none fp_one
    fp_none=$(fingerprint_pr_json "${pr}" "null" "${rc_none}")
    fp_one=$(fingerprint_pr_json "${pr}" "null" "${rc_one}")
    [ "${fp_none}" != "${fp_one}" ]
}

@test "fingerprint_pr_json defaults inline review comments to empty when the third argument is omitted (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local fp_omitted fp_explicit_empty
    fp_omitted=$(fingerprint_pr_json "${pr}")
    fp_explicit_empty=$(fingerprint_pr_json "${pr}" "null" "[]")
    [ "${fp_omitted}" = "${fp_explicit_empty}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted inline review comment changes fingerprint (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local rc_none='[]'
    local rc_trusted='[{"user":{"login":"owner"},"body":"Why this change?","updated_at":"2024-01-01T00:00:00Z"}]'
    local trusted='["owner"]'
    local fp_none fp_trusted
    fp_none=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_none}")
    fp_trusted=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_trusted}")
    [ "${fp_none}" != "${fp_trusted}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted inline review comment does not change fingerprint (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local rc_none='[]'
    local rc_untrusted='[{"user":{"login":"randomer"},"body":"spam","updated_at":"2024-01-01T00:00:00Z"}]'
    local trusted='["owner"]'
    local fp_none fp_untrusted
    fp_none=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_none}")
    fp_untrusted=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_untrusted}")
    [ "${fp_none}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json succeeds when inline review comments exceed 128KiB (#1254)" {
    # Linux caps a single execve argument at MAX_ARG_STRLEN (128KiB), well below the ~2MiB total
    # ARG_MAX. A PR with enough inline review comments serialises past that per-argument ceiling;
    # passing the blob to jq via --argjson (a command-line argument) used to fail with
    # "jq: Argument list too long" once a real PR (credfeto-docker-registry#8) crossed it.
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local big_body
    big_body=$(head -c 200000 /dev/zero | tr '\0' 'a')
    local rc="[{\"user\":{\"login\":\"bob\"},\"updated_at\":\"2024-01-01T00:00:00Z\",\"body\":\"${big_body}\"}]"

    run fingerprint_pr_json "${pr}" "null" "${rc}"
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}
