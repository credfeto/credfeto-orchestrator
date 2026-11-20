#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- issue post-plan (#1604) ------------------------------------------------------

POST_PLAN_ISSUE=1346
POST_PLAN_ISSUE_URL="https://github.com/${REPO}/issues/${POST_PLAN_ISSUE}"
POST_PLAN_COMMENT_URL="${POST_PLAN_ISSUE_URL}#issuecomment-81"
POST_PLAN_BOARD_EDIT="project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_2"

run_post_plan() {
    run --separate-stderr "${SCRIPT}" issue post-plan --repo "${REPO}" --issue "${POST_PLAN_ISSUE}" --body-file "${TEST_TMP}/plan.md"
}

# The issue to plan in the state $1 (OPEN by default) with the labels given as the further arguments,
# a plan body that passes every check, and the comment URL the post answers with.
prepare_post_plan() {
    local state="${1:-OPEN}"
    shift || true
    write_issue "${POST_PLAN_ISSUE}" "fix: something" "${state}" "The body." "$@"
    printf '%s\n' "${POST_PLAN_COMMENT_URL}" > "${GH_FIXTURES}/comment.out"
    printf '## Implementation Plan\n\n1. Do the thing.\n\nNo open questions.\n' > "${TEST_TMP}/plan.md"
}

# Nothing was written: no comment, no label and no board change.
assert_no_plan_written() {
    [ "$(gh_call_count "issue comment")" -eq 0 ]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "issue post-plan posts the plan, then adds Blocked, then moves the board to Planning, printing a line a step" {
    prepare_post_plan OPEN AI-Work
    run_post_plan
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${POST_PLAN_COMMENT_URL}
${POST_PLAN_ISSUE_URL} Blocked
${POST_PLAN_ISSUE_URL} Planning" ]
    cmp "${TEST_TMP}/plan.md" "${GH_FIXTURES}/comment-body.txt"
    [ "$(gh_call_count "issue view ${POST_PLAN_ISSUE} --repo ${REPO}")" -eq 1 ]
    grep -qxF "issue edit ${POST_PLAN_ISSUE} --repo ${REPO} --add-label Blocked" "${GH_LOG}"
    grep -qxF "project item-add 74 --owner credfeto --url ${POST_PLAN_ISSUE_URL} --format json --jq .id" "${GH_LOG}"
    grep -qxF "${POST_PLAN_BOARD_EDIT}" "${GH_LOG}"
    [ "$(gh_line_of "issue view")" -lt "$(gh_line_of "issue comment ${POST_PLAN_ISSUE}")" ]
    [ "$(gh_line_of "project field-list")" -lt "$(gh_line_of "issue comment ${POST_PLAN_ISSUE}")" ]
    [ "$(gh_line_of "issue comment ${POST_PLAN_ISSUE}")" -lt "$(gh_line_of "issue edit ${POST_PLAN_ISSUE}")" ]
    [ "$(gh_line_of "issue edit ${POST_PLAN_ISSUE}")" -lt "$(gh_line_of "project item-add")" ]
    [ "$(gh_call_count "issue comment")" -eq 1 ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
    [ "$(gh_call_count "api graphql")" -eq 0 ]
}

@test "issue post-plan reads the plan from stdin" {
    prepare_post_plan
    run --separate-stderr "${SCRIPT}" issue post-plan --repo "${REPO}" --issue "${POST_PLAN_ISSUE}" --body-file - < "${TEST_TMP}/plan.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/plan.md" "${GH_FIXTURES}/comment-body.txt"
}

@test "issue post-plan reports a repository with no Workflow board, rather than failing, after the comment and Blocked" {
    prepare_post_plan
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false}]}}' \
        > "${GH_FIXTURES}/repo-view.json"
    run_post_plan
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${POST_PLAN_COMMENT_URL}
${POST_PLAN_ISSUE_URL} Blocked
${POST_PLAN_ISSUE_URL} no board" ]
    [ "$(gh_call_count "issue edit ${POST_PLAN_ISSUE} --repo ${REPO} --add-label Blocked")" -eq 1 ]
    [ "$(gh_call_count "project ")" -eq 0 ]
}

@test "issue post-plan refuses (exit 8) a body without a line that is exactly the plan heading, before reading or writing anything" {
    local body
    prepare_post_plan
    for body in $'Plan:\n\n1. Do the thing.\n' $'## Implementation Plan:\n\n1. x\n' $'##Implementation Plan\n' $'## implementation plan\n' \
        $' ## Implementation Plan\n' $'Here is the ## Implementation Plan\n'; do
        printf '%s' "${body}" > "${TEST_TMP}/plan.md"
        : > "${GH_LOG}"
        run_post_plan
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: post-plan refused: the body has no line that is exactly ## Implementation Plan" ]
        [ "$(gh_call_count "issue view")" -eq 0 ]
        assert_no_plan_written
    done
}

@test "issue post-plan refuses (exit 8) a plan-approval keyword outside a quote, and posts one inside a quote" {
    local keyword
    prepare_post_plan
    for keyword in $(sign_off_keywords); do
        printf '## Implementation Plan\n\n%s\n' "${keyword}" > "${TEST_TMP}/plan.md"
        : > "${GH_LOG}"
        run_post_plan
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: body refused: approval keyword (line 3)" ]
        [ "$(gh_call_count "issue view")" -eq 0 ]
        assert_no_plan_written
    done
    printf '## Implementation Plan\n\n> %s\n\n1. Do the thing.\n' "$(sign_off_keywords | head -1)" > "${TEST_TMP}/plan.md"
    run_post_plan
    [ "${status}" -eq 0 ]
}

@test "issue post-plan refuses (exit 8) a body that fails the leak check, writing nothing" {
    prepare_post_plan
    printf '## Implementation Plan\n\ntoken ghp_%s\n' "$(printf 'a%.0s' {1..36})" > "${TEST_TMP}/plan.md"
    : > "${GH_LOG}"
    run_post_plan
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    [ "$(gh_call_count "issue view")" -eq 0 ]
    assert_no_plan_written
    printf '## Implementation Plan\n\nsee /home/someone/secret.txt\n' > "${TEST_TMP}/plan.md"
    : > "${GH_LOG}"
    run_post_plan
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    assert_no_plan_written
}

@test "issue post-plan refuses (exit 8) a closed issue, writing nothing" {
    prepare_post_plan CLOSED
    run_post_plan
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: post-plan refused: the issue is closed" ]
    assert_no_plan_written
}

@test "issue post-plan refuses (exit 8) an issue that carries On Hold, in any spelling, writing nothing" {
    local label
    for label in "On Hold" "on hold" "On-Hold"; do
        prepare_post_plan OPEN AI-Work "${label}"
        : > "${GH_LOG}"
        run_post_plan
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: post-plan refused: the issue carries On Hold" ]
        [ "$(gh_call_count "issue view")" -eq 1 ]
        assert_no_plan_written
    done
}

@test "issue post-plan exits 9 for a number that is no issue or is a pull request's, writing nothing" {
    printf '## Implementation Plan\n\n1. x\n' > "${TEST_TMP}/plan.md"
    run_post_plan
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${POST_PLAN_ISSUE} was not found" ]
    jq -n --arg url "https://github.com/${REPO}/pull/${POST_PLAN_ISSUE}" '{url: $url, state: "OPEN", labels: []}' > "$(issue_fixture "${POST_PLAN_ISSUE}").json"
    run_post_plan
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${POST_PLAN_ISSUE} is a pull request, not an issue" ]
    assert_no_plan_written
}

@test "issue post-plan writes nothing else when the comment cannot be posted" {
    prepare_post_plan
    touch "${GH_FIXTURES}/comment.fail"
    run_post_plan
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not post the comment on ${REPO}#${POST_PLAN_ISSUE}" ]]
    [[ "${stderr}" != *"steps done"* ]]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]

    rm "${GH_FIXTURES}/comment.fail"
    printf 'not a comment URL\n' > "${GH_FIXTURES}/comment.out"
    run_post_plan
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the comment, which may have been posted on ${REPO}#${POST_PLAN_ISSUE}" ]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
    [ "$(gh_call_count "project item-")" -eq 0 ]
}

@test "issue post-plan fails (exit 1) naming the comment URL when adding Blocked fails, and moves no board" {
    prepare_post_plan
    echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/issue-edit.fail"
    run_post_plan
    [ "${status}" -eq 1 ]
    [ "${output}" = "${POST_PLAN_COMMENT_URL}" ]
    [[ "${stderr}" == "cfwf: could not add the label Blocked to ${REPO}#${POST_PLAN_ISSUE}: HTTP 502: Bad Gateway"* ]]
    [[ "${stderr}" == *"cfwf: post-plan steps done before the failure: comment ${POST_PLAN_COMMENT_URL}" ]]
    [ "$(gh_call_count "project item-")" -eq 0 ]
}

@test "issue post-plan fails (exit 1) naming the comment URL and Blocked when the board write fails" {
    prepare_post_plan
    touch "${GH_FIXTURES}/item-edit.fail"
    run_post_plan
    [ "${status}" -eq 1 ]
    [ "${output}" = "${POST_PLAN_COMMENT_URL}
${POST_PLAN_ISSUE_URL} Blocked" ]
    [[ "${stderr}" == *"cfwf: could not set the Status of ${POST_PLAN_ISSUE_URL}"$'\n'* ]]
    [[ "${stderr}" == *"cfwf: post-plan steps done before the failure: comment ${POST_PLAN_COMMENT_URL}, Blocked" ]]
}

@test "issue post-plan fails (exit 1) before writing anything when the board cannot be read" {
    prepare_post_plan
    touch "${GH_FIXTURES}/repo-view.fail"
    run_post_plan
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"cfwf: could not read the projects of ${REPO}" ]]
    assert_no_plan_written
}

@test "issue post-plan usage errors exit 2 with its usage on stderr, before any gh call" {
    local args
    printf '## Implementation Plan\n\n1. x\n' > "${TEST_TMP}/plan.md"
    for args in "--repo ${REPO} --issue 1" "--repo ${REPO} --body-file ${TEST_TMP}/plan.md" \
        "--issue 1 --body-file ${TEST_TMP}/plan.md" "--repo ${REPO} --issue 0 --body-file ${TEST_TMP}/plan.md" \
        "--repo ${REPO} --issue 1a --body-file ${TEST_TMP}/plan.md" "--repo nope --issue 1 --body-file ${TEST_TMP}/plan.md" \
        "--repo ${REPO} --issue 1 --issue 2 --body-file ${TEST_TMP}/plan.md" \
        "--repo ${REPO} --issue 1 --body-file ${TEST_TMP}/plan.md --body-file ${TEST_TMP}/plan.md" \
        "--repo ${REPO} --issue 1 --body-file ${TEST_TMP}/plan.md --body text" \
        "--repo ${REPO} --pr 1 --body-file ${TEST_TMP}/plan.md" "--repo ${REPO} --issue 1 --body-file"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" issue post-plan ${args}
        [ "${status}" -eq 2 ]
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf issue post-plan --repo <owner/repo> --issue <n> --body-file <file|->"* ]]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "issue post-plan help, from -h, --help and help, gives the usage, the order, the refusals and the exit codes, help issue and the general help include it, and none calls gh" {
    local invocation
    for invocation in "issue post-plan -h" "issue post-plan --help" "help issue post-plan"; do
        # shellcheck disable=SC2086  # each invocation is several words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [[ "${output}" == "Usage: cfwf issue post-plan --repo <owner/repo> --issue <n> --body-file <file|->"* ]]
        [[ "${output}" == *"posts the body as a comment, adds the Blocked label, then moves the issue to Planning"* ]]
        [[ "${output}" == *'exactly "## Implementation Plan"'* ]]
        [[ "${output}" == *"must be open and must not carry On Hold"* ]]
        [[ "${output}" == *'"cfwf: post-plan refused: <rule>"'* ]]
        [[ "${output}" == *'"<url> no board"'* ]]
        [[ "${output}" == *"8 refused, nothing written"* ]]
        [[ "${output}" != *"usage_"* ]]
    done
    run "${SCRIPT}" help issue
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue close "*"Usage: cfwf issue post-plan "*"Usage: cfwf issue comments "* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  issue close              Close an issue with a reason, with an optional comment first (exit 8 when refused, 9 when not found)"$'\n'"  issue post-plan          Post an issue's implementation plan, add Blocked, then move the board to Planning (exit 8 when refused)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

# --- issue block and pr block (#1599) ----------------------------------------------

BLOCK_ISSUE=1599
BLOCK_PR=1623
BLOCK_SHA="0123456789abcdef0123456789abcdef01234567"

# The item URL of the kind $1 (issue or pr) and its comment URL.
block_item_url() {
    if [ "$1" = pr ]; then
        printf 'https://github.com/%s/pull/%s\n' "${REPO}" "${BLOCK_PR}"
    else
        printf 'https://github.com/%s/issues/%s\n' "${REPO}" "${BLOCK_ISSUE}"
    fi
}

block_comment_url() {
    printf '%s#issuecomment-99\n' "$(block_item_url "$1")"
}

block_flag() {
    if [ "$1" = pr ]; then
        printf -- '--pr %s\n' "${BLOCK_PR}"
    else
        printf -- '--issue %s\n' "${BLOCK_ISSUE}"
    fi
}

# Runs <kind> block ($1) on its item with the body file $2 (block.md by default).
run_block() {
    local kind="$1" body="${2:-${TEST_TMP}/block.md}"
    # shellcheck disable=SC2046  # the flag and its number are two words on purpose
    run --separate-stderr "${SCRIPT}" "${kind}" block --repo "${REPO}" $(block_flag "${kind}") --body-file "${body}"
}

# A body that passes every check, and the comment URL the post of the kind $1 answers with.
prepare_block() {
    block_comment_url "$1" > "${GH_FIXTURES}/comment.out"
    printf 'Which of the two behaviours is wanted?\n\nThe spec says both.\n' > "${TEST_TMP}/block.md"
}

# Nothing was written: no comment, no edit, no board change.
assert_nothing_blocked() {
    [ "$(gh_call_count " comment")" -eq 0 ]
    [ "$(gh_call_count " edit")" -eq 0 ]
    [ "$(gh_call_count "project ")" -eq 0 ]
}

@test "issue block and pr block post the comment, then add Blocked, printing the comment URL and the item URL, and touch nothing else" {
    local kind number
    for kind in issue pr; do
        number="${BLOCK_ISSUE}"
        [ "${kind}" = issue ] || number="${BLOCK_PR}"
        prepare_block "${kind}"
        : > "${GH_LOG}"
        run_block "${kind}"
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [ "${output}" = "$(block_comment_url "${kind}")
$(block_item_url "${kind}") Blocked" ]
        cmp "${TEST_TMP}/block.md" "${GH_FIXTURES}/comment-body.txt"
        [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
        issue_create_called_with "${kind} comment ${number} --repo ${REPO} --body-file BODY"
        sed -n 2p "${GH_LOG}" | grep -qxF "${kind} edit ${number} --repo ${REPO} --add-label Blocked"
        [ "$(gh_line_of "${kind} comment")" -lt "$(gh_line_of "${kind} edit")" ]
        [ "$(gh_call_count "project ")" -eq 0 ]
        [ "$(gh_call_count "api graphql")" -eq 0 ]
        [ "$(gh_call_count "--remove-label")" -eq 0 ]
        [ "$(gh_call_count "assignee")" -eq 0 ]
    done
}

@test "pr block reads the body from stdin" {
    prepare_block pr
    run --separate-stderr "${SCRIPT}" pr block --repo "${REPO}" --pr "${BLOCK_PR}" --body-file - < "${TEST_TMP}/block.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/block.md" "${GH_FIXTURES}/comment-body.txt"
}

@test "issue block and pr block still post the comment on an item that already carries Blocked, without reading it" {
    local kind
    write_issue "${BLOCK_ISSUE}" "fix: something" OPEN "The body." Blocked
    for kind in issue pr; do
        prepare_block "${kind}"
        : > "${GH_LOG}"
        run_block "${kind}"
        [ "${status}" -eq 0 ]
        [ "$(gh_call_count "${kind} comment")" -eq 1 ]
        [ "$(gh_call_count "${kind} edit")" -eq 1 ]
        [ "$(gh_call_count " view")" -eq 0 ]
    done
}

@test "issue block and pr block refuse (exit 8) a body that fails the leak check, writing nothing" {
    local kind
    for kind in issue pr; do
        prepare_block "${kind}"
        printf 'Why?\n\ntoken ghp_%s\n' "$(printf 'a%.0s' {1..36})" > "${TEST_TMP}/block.md"
        : > "${GH_LOG}"
        run_block "${kind}"
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: body refused: token (line 3)" ]
        assert_nothing_blocked
    done
}

@test "issue block and pr block refuse (exit 8) a plan-approval keyword outside a quote, writing nothing, and post one inside a quote" {
    local kind keyword
    for kind in issue pr; do
        prepare_block "${kind}"
        for keyword in $(sign_off_keywords); do
            printf 'Blocked on this.\n\n%s\n' "${keyword}" > "${TEST_TMP}/block.md"
            : > "${GH_LOG}"
            run_block "${kind}"
            [ "${status}" -eq 8 ]
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: body refused: approval keyword (line 3)" ]
            assert_nothing_blocked
        done
        printf 'You said:\n\n> %s\n\nbut which one?\n' "$(sign_off_keywords | head -1)" > "${TEST_TMP}/block.md"
        run_block "${kind}"
        [ "${status}" -eq 0 ]
    done
}

@test "pr block posts a well-formed environment-block marker, on its own line or after text" {
    local body
    prepare_block pr
    for body in "Missing pgrep in the image.\n\n<!-- orchestrator:env-block image-sha=${BLOCK_SHA} -->\n" \
        "Missing pgrep in the image. <!-- orchestrator:env-block image-sha=${BLOCK_SHA} -->\n"; do
        # shellcheck disable=SC2059  # the body is the format on purpose, for its \n
        printf "${body}" > "${TEST_TMP}/block.md"
        : > "${GH_LOG}"
        run_block pr
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        cmp "${TEST_TMP}/block.md" "${GH_FIXTURES}/comment-body.txt"
        [ "$(gh_call_count "pr edit ${BLOCK_PR} --repo ${REPO} --add-label Blocked")" -eq 1 ]
    done
}

@test "pr block refuses (exit 8) a malformed environment-block marker, naming its line and writing nothing" {
    local marker
    prepare_block pr
    for marker in "<!-- orchestrator:env-block image-sha=abc1234 -->" \
        "<!-- orchestrator:env-block image-sha=${BLOCK_SHA^^} -->" \
        "<!-- orchestrator:env-block image-sha= -->" \
        "<!-- orchestrator:env-block image-sha=unknown -->" \
        "<!-- orchestrator:env-block image-sha=${BLOCK_SHA}0 -->" \
        "<!-- orchestrator:env-block image-sha=${BLOCK_SHA}" \
        "<!--orchestrator:env-block image-sha=${BLOCK_SHA}-->" \
        "<!--  orchestrator:env-block  image-sha=${BLOCK_SHA} -->" \
        "<!-- ORCHESTRATOR:ENV-BLOCK image-sha=${BLOCK_SHA} -->" \
        "<!-- orchestrator:env-block sha=${BLOCK_SHA} -->" \
        "orchestrator:env-block" \
        "<!-- orchestrator:env-block image-sha=${BLOCK_SHA} --> orchestrator:env-block"; do
        printf 'Missing pgrep in the image.\n\n%s\n' "${marker}" > "${TEST_TMP}/block.md"
        : > "${GH_LOG}"
        run_block pr
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: body refused: malformed env-block marker (line 3)" ]
        assert_nothing_blocked
    done
}

@test "issue block refuses (exit 8) any environment-block marker, a well-formed one included, writing nothing" {
    local marker
    prepare_block issue
    for marker in "<!-- orchestrator:env-block image-sha=${BLOCK_SHA} -->" "<!-- orchestrator:env-block image-sha=abc1234 -->" \
        "Orchestrator:Env-Block"; do
        printf 'Missing pgrep in the image.\n\n%s\n' "${marker}" > "${TEST_TMP}/block.md"
        : > "${GH_LOG}"
        run_block issue
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: body refused: env-block marker on an issue (line 3)" ]
        assert_nothing_blocked
    done
}

@test "issue block and pr block write nothing else when the comment cannot be posted" {
    local kind
    for kind in issue pr; do
        prepare_block "${kind}"
        touch "${GH_FIXTURES}/comment.fail"
        : > "${GH_LOG}"
        run_block "${kind}"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [[ "${stderr}" == *"cfwf: could not post the comment on ${REPO}#"* ]]
        [[ "${stderr}" != *"already posted"* ]]
        [ "$(gh_call_count "${kind} edit")" -eq 0 ]
        rm "${GH_FIXTURES}/comment.fail"
    done
}

@test "issue block and pr block fail (exit 1) naming the comment URL when adding Blocked fails after the comment" {
    local kind number
    for kind in issue pr; do
        number="${BLOCK_ISSUE}"
        [ "${kind}" = issue ] || number="${BLOCK_PR}"
        prepare_block "${kind}"
        echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/${kind}-edit.fail"
        run_block "${kind}"
        [ "${status}" -eq 1 ]
        [ "${output}" = "$(block_comment_url "${kind}")" ]
        [[ "${stderr}" == "cfwf: could not add the label Blocked to ${REPO}#${number}: HTTP 502: Bad Gateway"$'\n'* ]]
        [[ "${stderr}" == *$'\n'"cfwf: the comment was already posted: $(block_comment_url "${kind}")" ]]
        [ "$(gh_call_count "project ")" -eq 0 ]
    done
}

# The usage errors of <kind> block: $1 is its number flag, $2 the other kind's, $3 the body file.
block_usage_cases() {
    local flag="$1" other="$2" body="$3"
    printf '%s\n' "--repo ${REPO} ${flag} 1" "--repo ${REPO} --body-file ${body}" "${flag} 1 --body-file ${body}" \
        "--repo ${REPO} ${flag} 0 --body-file ${body}" "--repo ${REPO} ${flag} 1a --body-file ${body}" \
        "--repo nope ${flag} 1 --body-file ${body}" "--repo ${REPO} ${flag} 1 ${flag} 2 --body-file ${body}" \
        "--repo ${REPO} ${flag} 1 --body-file ${body} --body-file ${body}" "--repo ${REPO} ${flag} 1 --body-file ${body} --body text" \
        "--repo ${REPO} ${other} 1 --body-file ${body}" "--repo ${REPO} ${flag} 1 --body-file" \
        "--repo ${REPO} ${flag} 1 --body-file ${body} --label x"
}

@test "issue block and pr block usage errors exit 2 with their usage on stderr, before any gh call" {
    local kind flag other args
    prepare_block issue
    for kind in issue pr; do
        flag="--issue"
        other="--pr"
        if [ "${kind}" = pr ]; then
            flag="--pr"
            other="--issue"
        fi
        while IFS= read -r args; do
            # shellcheck disable=SC2086  # each case is split into its words on purpose
            run --separate-stderr "${SCRIPT}" "${kind}" block ${args}
            [ "${status}" -eq 2 ]
            [ -z "${output}" ]
            [[ "${stderr}" == *"Usage: cfwf ${kind} block --repo <owner/repo> ${flag} <n> --body-file <file|->"* ]]
            [ ! -f "${GH_LOG}" ]
        done < <(block_usage_cases "${flag}" "${other}" "${TEST_TMP}/block.md")
    done
}

@test "issue block and pr block help, from -h, --help and help, gives the usage, the order, the marker rule and the exit codes, and none calls gh" {
    local kind invocation flag
    for kind in issue pr; do
        flag="--issue"
        [ "${kind}" = issue ] || flag="--pr"
        for invocation in "${kind} block -h" "${kind} block --help" "help ${kind} block"; do
            # shellcheck disable=SC2086  # each invocation is several words on purpose
            run --separate-stderr "${SCRIPT}" ${invocation}
            [ "${status}" -eq 0 ]
            [ -z "${stderr}" ]
            [[ "${output}" == "Usage: cfwf ${kind} block --repo <owner/repo> ${flag} <n> --body-file <file|->"* ]]
            [[ "${output}" == *"posts the body as"*"comment, then adds the Blocked label"* ]]
            [[ "${output}" == *"already carries Blocked still gets the comment"* ]]
            [[ "${output}" == *"board status, the assignees and every other label are left as they are"* ]]
            [[ "${output}" == *'"cfwf: body refused: <rule>"'* ]]
            [[ "${output}" == *"the message names the comment URL"* ]]
            [[ "${output}" == *"<url> Blocked"* ]]
            [[ "${output}" == *"8 refused, nothing written"* ]]
            [[ "${output}" != *"usage_"* ]]
            if [ "${kind}" = pr ]; then
                [[ "${output}" == *"exactly <!-- orchestrator:env-block image-sha=<sha> -->"*'("malformed env-block marker")'* ]]
            else
                [[ "${output}" == *'any marker is refused ("env-block marker on an issue")'* ]]
            fi
        done
    done
    run "${SCRIPT}" help issue
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue post-plan "*"Usage: cfwf issue block "*"Usage: cfwf issue comments "* ]]
    run "${SCRIPT}" help pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"Run 'cfwf pr block --help' for pr block, which posts a question on a pull request and adds Blocked."$'\n'* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  issue post-plan          Post an issue's implementation plan, add Blocked, then move the board to Planning (exit 8 when refused)"$'\n'"  issue block              Post a question on an issue, then add Blocked, leaving the board as it is (exit 8 when refused)"$'\n'* ]]
    [[ "${output}" == *$'\n'"  pr reopen                Reopen a closed PR, with an optional comment first (exit 8 refused, 9 not found)"$'\n'"  pr block                 Post a question on a PR, then add Blocked, leaving the board as it is (exit 8 when refused)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

# --- issue unblock and pr unblock ----------------------------------------------

UNBLOCK_ISSUE=1600
UNBLOCK_PR=1624

# The item URL of the kind $1 (issue or pr) and its comment URL.
unblock_item_url() {
    if [ "$1" = pr ]; then
        printf 'https://github.com/%s/pull/%s\n' "${REPO}" "${UNBLOCK_PR}"
    else
        printf 'https://github.com/%s/issues/%s\n' "${REPO}" "${UNBLOCK_ISSUE}"
    fi
}

unblock_comment_url() {
    printf '%s#issuecomment-77\n' "$(unblock_item_url "$1")"
}

unblock_number() {
    if [ "$1" = pr ]; then
        printf '%s\n' "${UNBLOCK_PR}"
    else
        printf '%s\n' "${UNBLOCK_ISSUE}"
    fi
}

unblock_flag() {
    if [ "$1" = pr ]; then
        printf -- '--pr\n'
    else
        printf -- '--issue\n'
    fi
}

# Writes the by-number answer for the issue and the pull request on the Workflow project, both with
# the board status $1, "null" for an item on the board with no status, or "absent" for one that is
# on the decoy project only.
write_unblock_board() {
    jq -n --arg s "$1" '
        (if $s == "absent" then [] elif $s == "null" then [{project: {id: "PVT_proj"}, legacy: null, status: null}]
         else [{project: {id: "PVT_proj"}, legacy: null, status: {name: $s}}] end) as $item
        | {data: {repository: {
            issue: {projectItems: {nodes: ([{project: {id: "PVT_other"}, legacy: null, status: {name: "Complete"}}] + $item)}},
            pullRequest: {projectItems: {nodes: ([{project: {id: "PVT_other"}, legacy: null, status: {name: "Complete"}}] + $item)}}}}}' \
        > "${GH_FIXTURES}/graphql-target.json"
}

# Runs <kind> unblock ($1) on its item with the body file $2 (unblock.md by default), outside an
# agent session.
run_unblock() {
    local kind="$1" body="${2:-${TEST_TMP}/unblock.md}"
    unset CLAUDECODE
    run --separate-stderr "${SCRIPT}" "${kind}" unblock --repo "${REPO}" "$(unblock_flag "${kind}")" "$(unblock_number "${kind}")" --body-file "${body}"
}

# A body that passes every check, the comment URL the post of the kind $1 answers with, and the
# board at Approved.
prepare_unblock() {
    unblock_comment_url "$1" > "${GH_FIXTURES}/comment.out"
    printf 'Answered in chat: go with the second behaviour.\n' > "${TEST_TMP}/unblock.md"
    write_unblock_board Approved
}

# Nothing was written: no comment, no label change, no board change.
assert_nothing_unblocked() {
    [ "$(gh_call_count " comment")" -eq 0 ]
    [ "$(gh_call_count " edit")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "issue unblock and pr unblock refuse (exit 10) in an AI agent session, before any option is read or gh is called" {
    local kind args
    prepare_unblock issue
    for kind in issue pr; do
        for args in "--repo ${REPO} $(unblock_flag "${kind}") $(unblock_number "${kind}") --body-file ${TEST_TMP}/unblock.md" \
            "" "--repo nope" "--frobnicate" "-h" "--help"; do
            rm -f "${GH_LOG}"
            # shellcheck disable=SC2086  # each case is split into its words on purpose
            CLAUDECODE=1 run --separate-stderr "${SCRIPT}" "${kind}" unblock ${args}
            [ "${status}" -eq 10 ] || {
                echo "${kind} [${args}]: ${status}" >&2
                return 1
            }
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: ${kind} unblock refused: not allowed for agents; a human must run it" ]
            [ ! -f "${GH_LOG}" ]
        done
    done
}

@test "issue unblock and pr unblock post the comment, then remove Blocked, printing the comment URL and '<url> unblocked'" {
    local kind number
    for kind in issue pr; do
        number="$(unblock_number "${kind}")"
        prepare_unblock "${kind}"
        : > "${GH_LOG}"
        run_unblock "${kind}"
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [ "${output}" = "$(unblock_comment_url "${kind}")
$(unblock_item_url "${kind}") unblocked" ]
        cmp "${TEST_TMP}/unblock.md" "${GH_FIXTURES}/comment-body.txt"
        issue_create_called_with "${kind} comment ${number} --repo ${REPO} --body-file BODY"
        tail -n 1 "${GH_LOG}" | grep -qxF "${kind} edit ${number} --repo ${REPO} --remove-label Blocked"
        [ "$(gh_line_of "${kind} comment")" -lt "$(gh_line_of "${kind} edit")" ]
        [ "$(gh_call_count " edit")" -eq 1 ]
        [ "$(gh_call_count "--add-label")" -eq 0 ]
        [ "$(gh_call_count "project item-add")" -eq 0 ]
        [ "$(gh_call_count "project item-edit")" -eq 0 ]
        [ "$(gh_call_count "assignee")" -eq 0 ]
    done
}

@test "issue unblock and pr unblock run with CLAUDECODE set to anything other than 1" {
    local kind value
    for kind in issue pr; do
        prepare_unblock "${kind}"
        for value in 0 "" true; do
            : > "${GH_LOG}"
            CLAUDECODE="${value}" run --separate-stderr "${SCRIPT}" "${kind}" unblock --repo "${REPO}" \
                "$(unblock_flag "${kind}")" "$(unblock_number "${kind}")" --body-file "${TEST_TMP}/unblock.md"
            [ "${status}" -eq 0 ] || {
                echo "${kind} [${value}]: ${status} ${stderr}" >&2
                return 1
            }
            [ "$(gh_call_count "--remove-label Blocked")" -eq 1 ]
        done
    done
}

@test "pr unblock reads the body from stdin" {
    prepare_unblock pr
    unset CLAUDECODE
    run --separate-stderr "${SCRIPT}" pr unblock --repo "${REPO}" --pr "${UNBLOCK_PR}" --body-file - < "${TEST_TMP}/unblock.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/unblock.md" "${GH_FIXTURES}/comment-body.txt"
}

@test "issue unblock and pr unblock remove only Blocked, never On Hold" {
    local kind
    write_issue "${UNBLOCK_ISSUE}" "fix: something" OPEN "The body." Blocked "On Hold"
    for kind in issue pr; do
        prepare_unblock "${kind}"
        : > "${GH_LOG}"
        run_unblock "${kind}"
        [ "${status}" -eq 0 ]
        [ "$(gh_call_count "--remove-label")" -eq 1 ]
        [ "$(gh_call_count "--remove-label Blocked")" -eq 1 ]
        [ "$(gh_call_count "On Hold")" -eq 0 ]
        [ "$(gh_call_count "On-Hold")" -eq 0 ]
        [ "$(gh_call_count "issue view")" -eq 0 ]
        [ "$(gh_call_count "pr view")" -eq 0 ]
    done
}

@test "issue unblock and pr unblock run at every board state from Approved on" {
    local kind state
    for kind in issue pr; do
        prepare_unblock "${kind}"
        for state in Approved Development "AI Simplify" "AI Review" "AI Security Review" "AI Coverage" "Human Review" Complete; do
            write_unblock_board "${state}"
            : > "${GH_LOG}"
            run_unblock "${kind}"
            [ "${status}" -eq 0 ] || {
                echo "${kind} ${state}: ${status} ${stderr}" >&2
                return 1
            }
            [ "$(gh_call_count "--remove-label Blocked")" -eq 1 ]
            [ "$(gh_call_count "project item-edit")" -eq 0 ]
        done
    done
}

@test "issue unblock and pr unblock refuse (exit 8) before Approved, with no status or off the board, writing nothing" {
    local kind state rule
    for kind in issue pr; do
        prepare_unblock "${kind}"
        for state in "Not Started" Planning null absent; do
            write_unblock_board "${state}"
            case "${state}" in
                null) rule="the board status is (unset), not Approved or later; it must be approved first" ;;
                absent) rule="${REPO}#$(unblock_number "${kind}") is not on the Workflow board; it must be Approved or later" ;;
                *) rule="the board status is ${state}, not Approved or later; it must be approved first" ;;
            esac
            : > "${GH_LOG}"
            run_unblock "${kind}"
            [ "${status}" -eq 8 ] || {
                echo "${kind} ${state}: ${status}" >&2
                return 1
            }
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: unblock refused: ${rule}" ]
            [ "$(gh_call_count "api graphql")" -eq 1 ]
            assert_nothing_unblocked
        done
    done
}

@test "issue unblock and pr unblock read the board from the listing when the direct read fails, and refuse before Approved" {
    use_fallback
    write_item_list Planning
    prepare_unblock issue
    printf 'https://github.com/%s/issues/1346#issuecomment-77\n' "${REPO}" > "${GH_FIXTURES}/comment.out"
    : > "${GH_LOG}"
    unset CLAUDECODE
    run --separate-stderr "${SCRIPT}" issue unblock --repo "${REPO}" --issue 1346 --body-file "${TEST_TMP}/unblock.md"
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == *"cfwf: unblock refused: the board status is Planning, not Approved or later; it must be approved first" ]]
    [ "$(gh_call_count "project item-list")" -eq 1 ]
    assert_nothing_unblocked
    write_item_list Development
    : > "${GH_LOG}"
    run --separate-stderr "${SCRIPT}" issue unblock --repo "${REPO}" --issue 1346 --body-file "${TEST_TMP}/unblock.md"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "issue edit 1346 --repo ${REPO} --remove-label Blocked")" -eq 1 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "issue unblock and pr unblock skip the board check in a repository with no Workflow board" {
    local kind
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false}]}}' \
        > "${GH_FIXTURES}/repo-view.json"
    for kind in issue pr; do
        prepare_unblock "${kind}"
        write_unblock_board Planning
        : > "${GH_LOG}"
        run_unblock "${kind}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(unblock_comment_url "${kind}")
$(unblock_item_url "${kind}") unblocked" ]
        [ "$(gh_call_count "api graphql")" -eq 0 ]
        [ "$(gh_call_count "project ")" -eq 0 ]
        [ "$(gh_call_count "--remove-label Blocked")" -eq 1 ]
    done
}

@test "issue unblock and pr unblock refuse (exit 8) a body that fails the leak check, writing nothing and reading no board" {
    local kind
    for kind in issue pr; do
        prepare_unblock "${kind}"
        printf 'Go ahead.\n\ntoken ghp_%s\n' "$(printf 'a%.0s' {1..36})" > "${TEST_TMP}/unblock.md"
        : > "${GH_LOG}"
        run_unblock "${kind}"
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: body refused: token (line 3)" ]
        [ "$(gh_call_count "api graphql")" -eq 0 ]
        assert_nothing_unblocked
    done
}

@test "issue unblock and pr unblock refuse (exit 8) a plan-approval keyword outside a quote, as comment add does, and post one inside a quote" {
    local kind keyword
    for kind in issue pr; do
        prepare_unblock "${kind}"
        for keyword in $(sign_off_keywords); do
            printf 'Unblocking.\n\n%s\n' "${keyword}" > "${TEST_TMP}/unblock.md"
            : > "${GH_LOG}"
            run_unblock "${kind}"
            [ "${status}" -eq 8 ]
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: body refused: approval keyword (line 3)" ]
            assert_nothing_unblocked
        done
        printf 'You said:\n\n> %s\n\nso this is unblocked.\n' "$(sign_off_keywords | head -1)" > "${TEST_TMP}/unblock.md"
        run_unblock "${kind}"
        [ "${status}" -eq 0 ]
    done
}

@test "issue unblock and pr unblock refuse an empty or blank body (exit 1), writing nothing" {
    local kind body
    for kind in issue pr; do
        prepare_unblock "${kind}"
        for body in '' '   \n\t\n'; do
            # shellcheck disable=SC2059  # the body is the format on purpose, for its \n
            printf "${body}" > "${TEST_TMP}/unblock.md"
            : > "${GH_LOG}"
            run_unblock "${kind}"
            [ "${status}" -eq 1 ]
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: the body is empty" ]
            assert_nothing_unblocked
        done
    done
}

@test "issue unblock and pr unblock write nothing else when the comment cannot be posted" {
    local kind
    for kind in issue pr; do
        prepare_unblock "${kind}"
        touch "${GH_FIXTURES}/comment.fail"
        : > "${GH_LOG}"
        run_unblock "${kind}"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [[ "${stderr}" == *"cfwf: could not post the comment on ${REPO}#"* ]]
        [[ "${stderr}" != *"already posted"* ]]
        [ "$(gh_call_count "${kind} edit")" -eq 0 ]
        rm "${GH_FIXTURES}/comment.fail"
    done
}

@test "issue unblock and pr unblock fail (exit 1) naming the comment URL when removing Blocked fails after the comment" {
    local kind number
    for kind in issue pr; do
        number="$(unblock_number "${kind}")"
        prepare_unblock "${kind}"
        echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/${kind}-edit.fail"
        run_unblock "${kind}"
        [ "${status}" -eq 1 ]
        [ "${output}" = "$(unblock_comment_url "${kind}")" ]
        [[ "${stderr}" == "cfwf: could not remove the label Blocked from ${REPO}#${number}: HTTP 502: Bad Gateway"$'\n'* ]]
        [[ "${stderr}" == *$'\n'"cfwf: the comment was already posted: $(unblock_comment_url "${kind}")" ]]
        [ "$(gh_call_count "project item-edit")" -eq 0 ]
    done
}

@test "issue unblock and pr unblock usage errors exit 2 with their usage on stderr, before any gh call" {
    local kind flag other args
    prepare_unblock issue
    unset CLAUDECODE
    for kind in issue pr; do
        flag="--issue"
        other="--pr"
        if [ "${kind}" = pr ]; then
            flag="--pr"
            other="--issue"
        fi
        while IFS= read -r args; do
            # shellcheck disable=SC2086  # each case is split into its words on purpose
            run --separate-stderr "${SCRIPT}" "${kind}" unblock ${args}
            [ "${status}" -eq 2 ] || {
                echo "${kind} [${args}]: ${status}" >&2
                return 1
            }
            [ -z "${output}" ]
            [[ "${stderr}" == *"Usage: cfwf ${kind} unblock --repo <owner/repo> ${flag} <n> --body-file <file|->"* ]]
            [ ! -f "${GH_LOG}" ]
        done < <(block_usage_cases "${flag}" "${other}" "${TEST_TMP}/unblock.md")
    done
}

@test "issue unblock and pr unblock help, from -h, --help and help, says they are for humans only and exit 10 for agents, and none calls gh" {
    local kind invocation flag
    unset CLAUDECODE
    for kind in issue pr; do
        flag="--issue"
        [ "${kind}" = issue ] || flag="--pr"
        for invocation in "${kind} unblock -h" "${kind} unblock --help" "help ${kind} unblock"; do
            # shellcheck disable=SC2086  # each invocation is several words on purpose
            run --separate-stderr "${SCRIPT}" ${invocation}
            [ "${status}" -eq 0 ]
            [ -z "${stderr}" ]
            [[ "${output}" == "Usage: cfwf ${kind} unblock --repo <owner/repo> ${flag} <n> --body-file <file|->"* ]]
            [[ "${output}" == *"For humans only. In an AI agent session (CLAUDECODE=1) it is refused with exit 10 (not allowed"$'\n'"for agents; a human must run it)"* ]]
            [[ "${output}" == *"posts the body as a comment, then removes"$'\n'"the Blocked label"* ]]
            [[ "${output}" == *"On Hold is never"$'\n'"removed"* ]]
            [[ "${output}" == *"at Approved or a"* ]]
            [[ "${output}" == *"This command never sets the board"* ]]
            [[ "${output}" == *'"cfwf: unblock refused: <rule>"'* ]]
            [[ "${output}" == *"<url> unblocked"* ]]
            [[ "${output}" == *"8 refused, nothing written; 10 not allowed for agents, nothing called or written."* ]]
            [[ "${output}" != *"usage_"* ]]
        done
    done
    CLAUDECODE=1 run --separate-stderr "${SCRIPT}" help issue unblock
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf issue unblock "* ]]
    run "${SCRIPT}" help issue
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue block "*"Usage: cfwf issue unblock "*"Usage: cfwf issue comments "* ]]
    run "${SCRIPT}" help pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"Run 'cfwf help pr unblock' for pr unblock, for humans only, which posts a comment on a pull request"$'\n'"and removes Blocked."$'\n'* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  issue block              Post a question on an issue, then add Blocked, leaving the board as it is (exit 8 when refused)"$'\n'"  issue unblock            Humans only: post a comment, then remove Blocked, once the board is Approved or later (exit 8 refused, 10 agent)"$'\n'* ]]
    [[ "${output}" == *$'\n'"  pr block                 Post a question on a PR, then add Blocked, leaving the board as it is (exit 8 when refused)"$'\n'"  pr unblock               Humans only: post a comment, then remove Blocked, once the board is Approved or later (exit 8 refused, 10 agent)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

# --- issue approve (#1607) -------------------------------------------------------

APPROVE_ISSUE=1607
APPROVE_ISSUE_URL="https://github.com/${REPO}/issues/${APPROVE_ISSUE}"
APPROVE_COMMENT_URL="${APPROVE_ISSUE_URL}#issuecomment-91"
APPROVE_BOARD_EDIT="project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_3"
APPROVE_USAGE="Usage: cfwf issue approve --repo <owner/repo> --issue <n> --body-file <file|-> [--keep-blocked]"

# Runs issue approve on its issue with approve.md and any further arguments, outside an agent session.
run_approve() {
    unset CLAUDECODE
    run --separate-stderr "${SCRIPT}" issue approve --repo "${REPO}" --issue "${APPROVE_ISSUE}" --body-file "${TEST_TMP}/approve.md" "$@"
}

# The issue to approve in the state $1 (OPEN by default) with the labels given as the further
# arguments (Blocked when none are given) and a plan comment, a body that passes every check, and
# the comment URL the post answers with.
prepare_approve() {
    local state="${1:-OPEN}"
    shift || true
    [ "$#" -gt 0 ] || set -- Blocked
    write_issue "${APPROVE_ISSUE}" "fix: something" "${state}" "The body." "$@"
    write_comments "${APPROVE_ISSUE}" \
        "$(issue_comment 1 steward-warden COLLABORATOR $'## Implementation Plan\n\n1. Do the thing.\n')" \
        "$(issue_comment 2 credfeto OWNER 'One question answered in chat.')"
    printf '%s\n' "${APPROVE_COMMENT_URL}" > "${GH_FIXTURES}/comment.out"
    printf 'Go ahead with the plan as written.\n' > "${TEST_TMP}/approve.md"
}

# Nothing was written: no comment, no label change and no board change.
assert_nothing_approved() {
    [ "$(gh_call_count "issue comment")" -eq 0 ]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "issue approve refuses (exit 10) in an AI agent session, before any option is read or gh is called" {
    local args
    prepare_approve
    for args in "--repo ${REPO} --issue ${APPROVE_ISSUE} --body-file ${TEST_TMP}/approve.md" \
        "--repo ${REPO} --issue ${APPROVE_ISSUE} --body-file ${TEST_TMP}/approve.md --keep-blocked" \
        "" "--repo nope" "--frobnicate" "-h" "--help"; do
        rm -f "${GH_LOG}"
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        CLAUDECODE=1 run --separate-stderr "${SCRIPT}" issue approve ${args}
        [ "${status}" -eq 10 ] || {
            echo "[${args}]: ${status}" >&2
            return 1
        }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: issue approve refused: not allowed for agents; a human must run it" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "issue approve posts the comment, then sets the board to Approved, then removes Blocked, printing the comment URL and 'Approved <url>'" {
    prepare_approve
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${APPROVE_COMMENT_URL}
Approved ${APPROVE_ISSUE_URL}" ]
    cmp "${TEST_TMP}/approve.md" "${GH_FIXTURES}/comment-body.txt"
    [ "$(gh_call_count "issue view ${APPROVE_ISSUE} --repo ${REPO}")" -eq 1 ]
    issue_create_called_with "issue comment ${APPROVE_ISSUE} --repo ${REPO} --body-file BODY"
    grep -qxF "project item-add 74 --owner credfeto --url ${APPROVE_ISSUE_URL} --format json --jq .id" "${GH_LOG}"
    grep -qxF "${APPROVE_BOARD_EDIT}" "${GH_LOG}"
    tail -n 1 "${GH_LOG}" | grep -qxF "issue edit ${APPROVE_ISSUE} --repo ${REPO} --remove-label Blocked"
    [ "$(gh_line_of "issue view")" -lt "$(gh_line_of "issue comment ${APPROVE_ISSUE}")" ]
    [ "$(gh_line_of "project field-list")" -lt "$(gh_line_of "issue comment ${APPROVE_ISSUE}")" ]
    [ "$(gh_line_of "issue comment ${APPROVE_ISSUE}")" -lt "$(gh_line_of "project item-add")" ]
    [ "$(gh_line_of "project item-add")" -lt "$(gh_line_of "project item-edit")" ]
    [ "$(gh_line_of "project item-edit")" -lt "$(gh_line_of "issue edit ${APPROVE_ISSUE}")" ]
    [ "$(gh_call_count "issue comment")" -eq 1 ]
    [ "$(gh_call_count "issue edit")" -eq 1 ]
    [ "$(gh_call_count "--add-label")" -eq 0 ]
    [ "$(gh_call_count "assignee")" -eq 0 ]
    # No read-back of the board, which lags behind writes.
    [ "$(gh_call_count "api graphql")" -eq 0 ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
}

@test "issue approve reads the body from stdin" {
    prepare_approve
    unset CLAUDECODE
    run --separate-stderr "${SCRIPT}" issue approve --repo "${REPO}" --issue "${APPROVE_ISSUE}" --body-file - < "${TEST_TMP}/approve.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/approve.md" "${GH_FIXTURES}/comment-body.txt"
}

@test "issue approve runs with CLAUDECODE set to anything other than 1" {
    local value
    prepare_approve
    for value in 0 "" true; do
        : > "${GH_LOG}"
        CLAUDECODE="${value}" run --separate-stderr "${SCRIPT}" issue approve --repo "${REPO}" --issue "${APPROVE_ISSUE}" --body-file "${TEST_TMP}/approve.md"
        [ "${status}" -eq 0 ] || {
            echo "[${value}]: ${status} ${stderr}" >&2
            return 1
        }
        [ "$(gh_call_count "--remove-label Blocked")" -eq 1 ]
    done
}

@test "issue approve --keep-blocked comments and sets Approved but leaves Blocked, printing '(Blocked kept)'" {
    prepare_approve
    : > "${GH_LOG}"
    run_approve --keep-blocked
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${APPROVE_COMMENT_URL}
Approved ${APPROVE_ISSUE_URL} (Blocked kept)" ]
    [ "$(gh_call_count "issue comment ${APPROVE_ISSUE}")" -eq 1 ]
    grep -qxF "${APPROVE_BOARD_EDIT}" "${GH_LOG}"
    [ "$(gh_call_count "issue edit")" -eq 0 ]
    [ "$(gh_call_count "--remove-label")" -eq 0 ]
}

@test "issue approve never removes On Hold, with or without --keep-blocked" {
    local label
    for label in "On Hold" "On-Hold"; do
        prepare_approve OPEN Blocked "${label}"
        : > "${GH_LOG}"
        run_approve
        [ "${status}" -eq 0 ]
        [ "$(gh_call_count "--remove-label")" -eq 1 ]
        [ "$(gh_call_count "--remove-label Blocked")" -eq 1 ]
        [ "$(gh_call_count "On Hold")" -eq 0 ]
        [ "$(gh_call_count "On-Hold")" -eq 0 ]
        : > "${GH_LOG}"
        run_approve --keep-blocked
        [ "${status}" -eq 0 ]
        [ "$(gh_call_count "--remove-label")" -eq 0 ]
    done
}

@test "issue approve in a repository with no Workflow board comments and removes Blocked, and says the board was not set" {
    prepare_approve
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false}]}}' \
        > "${GH_FIXTURES}/repo-view.json"
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 0 ]
    [ "${output}" = "${APPROVE_COMMENT_URL}
Approved ${APPROVE_ISSUE_URL}" ]
    [ "${stderr}" = "cfwf: warning: no project titled Workflow is linked to ${REPO}, so the board was not set" ]
    [ "$(gh_call_count "issue comment ${APPROVE_ISSUE}")" -eq 1 ]
    [ "$(gh_call_count "project ")" -eq 0 ]
    [ "$(gh_line_of "issue comment ${APPROVE_ISSUE}")" -lt "$(gh_line_of "issue edit ${APPROVE_ISSUE} --repo ${REPO} --remove-label Blocked")" ]
}

@test "issue approve posts a body with a plan-approval keyword, because the comment is the approval" {
    local keyword
    prepare_approve
    for keyword in $(sign_off_keywords); do
        printf 'Plan %s.\n' "${keyword}" > "${TEST_TMP}/approve.md"
        : > "${GH_LOG}"
        run_approve
        [ "${status}" -eq 0 ]
        cmp "${TEST_TMP}/approve.md" "${GH_FIXTURES}/comment-body.txt"
    done
}

@test "issue approve refuses (exit 8) a body that fails the leak check, reading and writing nothing" {
    prepare_approve
    printf 'Go ahead.\n\ntoken ghp_%s\n' "$(printf 'a%.0s' {1..36})" > "${TEST_TMP}/approve.md"
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: body refused: token (line 3)" ]
    [ "$(gh_call_count "issue view")" -eq 0 ]
    [ "$(gh_call_count "project ")" -eq 0 ]
    assert_nothing_approved
}

@test "issue approve refuses an empty or blank body (exit 1), writing nothing" {
    local body
    prepare_approve
    for body in '' '   \n\t\n'; do
        # shellcheck disable=SC2059  # the body is the format on purpose, for its \n
        printf "${body}" > "${TEST_TMP}/approve.md"
        : > "${GH_LOG}"
        run_approve
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the body is empty" ]
        assert_nothing_approved
    done
}

@test "issue approve refuses (exit 8) a pull request's number, writing nothing" {
    prepare_approve
    jq -n --arg url "https://github.com/${REPO}/pull/${APPROVE_ISSUE}" '{url: $url, state: "OPEN", labels: [], comments: []}' \
        > "$(issue_fixture "${APPROVE_ISSUE}").json"
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: approve refused: ${REPO}#${APPROVE_ISSUE} is a pull request, not an issue" ]
    [ "$(gh_call_count "project ")" -eq 0 ]
    assert_nothing_approved
}

@test "issue approve refuses (exit 8) a closed issue, writing nothing" {
    prepare_approve CLOSED
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: approve refused: the issue is closed" ]
    [ "$(gh_call_count "project ")" -eq 0 ]
    assert_nothing_approved
}

@test "issue approve refuses (exit 8) an issue with no comment that has a line that is exactly the plan heading, writing nothing" {
    local body
    for body in "" $'## Implementation Plan:\n\n1. x' $'##Implementation Plan\n' $'## implementation plan\n' \
        $' ## Implementation Plan\n' $'> ## Implementation Plan\n' $'Here is the ## Implementation Plan\n'; do
        prepare_approve
        if [ -z "${body}" ]; then
            write_comments "${APPROVE_ISSUE}"
        else
            write_comments "${APPROVE_ISSUE}" "$(issue_comment 1 steward-warden COLLABORATOR "${body}")"
        fi
        : > "${GH_LOG}"
        run_approve
        [ "${status}" -eq 8 ] || {
            echo "[${body}]: ${status}" >&2
            return 1
        }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: approve refused: the issue has no comment with a line that is exactly ## Implementation Plan; there is nothing to approve" ]
        [ "$(gh_call_count "project ")" -eq 0 ]
        assert_nothing_approved
    done
}

@test "issue approve finds a plan heading followed by a CR, as GitHub keeps one from a browser" {
    prepare_approve
    write_comments "${APPROVE_ISSUE}" "$(issue_comment 1 steward-warden COLLABORATOR $'Intro\r\n## Implementation Plan\r\n\r\n1. x\r\n')"
    run_approve
    [ "${status}" -eq 0 ]
}

@test "issue approve exits 9 for a number that is no issue, writing nothing" {
    prepare_approve
    rm "$(issue_fixture "${APPROVE_ISSUE}").json"
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#${APPROVE_ISSUE} was not found" ]
    assert_nothing_approved
}

@test "issue approve writes nothing else when the comment cannot be posted" {
    prepare_approve
    touch "${GH_FIXTURES}/comment.fail"
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not post the comment on ${REPO}#${APPROVE_ISSUE}" ]]
    [[ "${stderr}" != *"steps done"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
}

@test "issue approve fails (exit 1) naming the comment when the board cannot be set, and leaves Blocked" {
    prepare_approve
    touch "${GH_FIXTURES}/item-edit.fail"
    : > "${GH_LOG}"
    run_approve
    [ "${status}" -eq 1 ]
    [ "${output}" = "${APPROVE_COMMENT_URL}" ]
    [[ "${stderr}" == *"cfwf: could not set the Status of ${APPROVE_ISSUE_URL}"$'\n'* ]]
    [[ "${stderr}" == *$'\n'"cfwf: approve steps done before the failure: comment ${APPROVE_COMMENT_URL}" ]]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
}

@test "issue approve fails (exit 1) naming the comment and the board when removing Blocked fails" {
    prepare_approve
    echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/issue-edit.fail"
    run_approve
    [ "${status}" -eq 1 ]
    [ "${output}" = "${APPROVE_COMMENT_URL}" ]
    [[ "${stderr}" == "cfwf: could not remove the label Blocked from ${REPO}#${APPROVE_ISSUE}: HTTP 502: Bad Gateway"$'\n'* ]]
    [[ "${stderr}" == *$'\n'"cfwf: approve steps done before the failure: comment ${APPROVE_COMMENT_URL}, board Approved" ]]
}

@test "issue approve usage errors exit 2 with its usage on stderr, before any gh call" {
    local args
    prepare_approve
    unset CLAUDECODE
    while IFS= read -r args; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" issue approve ${args}
        [ "${status}" -eq 2 ] || {
            echo "[${args}]: ${status}" >&2
            return 1
        }
        [ -z "${output}" ]
        [[ "${stderr}" == *"${APPROVE_USAGE}"* ]]
        [ ! -f "${GH_LOG}" ]
    done < <(
        block_usage_cases --issue --pr "${TEST_TMP}/approve.md"
        printf '%s\n' "--repo ${REPO} --issue 1 --body-file ${TEST_TMP}/approve.md --keep-blocked --keep-blocked" \
            "--repo ${REPO} --issue 1 --body-file ${TEST_TMP}/approve.md --keep-blocked=yes" \
            "--repo ${REPO} --issue 1 --body-file ${TEST_TMP}/approve.md --status Approved"
    )
}

@test "issue approve help, from -h, --help and help, says it is for humans only, gives the order and the exit codes, and none calls gh" {
    local invocation
    unset CLAUDECODE
    for invocation in "issue approve -h" "issue approve --help" "help issue approve"; do
        # shellcheck disable=SC2086  # each invocation is several words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [[ "${output}" == "${APPROVE_USAGE}"* ]]
        [[ "${output}" == *"For humans only. In an AI agent session (CLAUDECODE=1) it is refused with exit 10 (not allowed"$'\n'"for agents; a human must run it)"* ]]
        [[ "${output}" == *"posts the body as a"$'\n'"comment, sets the issue's status on the Workflow board to Approved"* ]]
        [[ "${output}" == *"then removes the Blocked label unless --keep-blocked is given. On Hold is never"$'\n'"removed"* ]]
        [[ "${output}" == *"exactly ## Implementation Plan"* ]]
        [[ "${output}" == *'"cfwf: approve refused: <rule>"'* ]]
        [[ "${output}" == *"Approved <url>"*'"Approved <url> (Blocked kept)" with --keep-blocked'* ]]
        [[ "${output}" == *"8 refused, nothing written; 9 not found, nothing written;"$'\n'"10 not allowed for agents, nothing called or written."* ]]
        [[ "${output}" != *"usage_"* ]]
    done
    CLAUDECODE=1 run --separate-stderr "${SCRIPT}" help issue approve
    [ "${status}" -eq 0 ]
    [[ "${output}" == "${APPROVE_USAGE}"* ]]
    run "${SCRIPT}" help issue
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue unblock "*"${APPROVE_USAGE}"*"Usage: cfwf issue comments "* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  issue unblock            Humans only: post a comment, then remove Blocked, once the board is Approved or later (exit 8 refused, 10 agent)"$'\n'"  issue approve            Humans only: post the plan approval, set the board to Approved, then remove Blocked (exit 8 refused, 10 agent)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "the agents' permissions deny ScheduleWakeup and the cron tools, so a finished session cannot idle in the container" {
    local settings="${REPO_ROOT}/containers/base/development-full/claude-managed-settings.json"
    local entry
    for entry in ScheduleWakeup CronCreate CronDelete CronList; do
        jq -r '.permissions.deny[]' "${settings}" | grep -qxF "${entry}"
        ! jq -r '.permissions.allow[]' "${settings}" | grep -qxF "${entry}"
    done
}

@test "the agents' permissions deny the human-only commands and their MCP tools, while cfwf as a whole stays allowed" {
    local settings="${REPO_ROOT}/containers/base/development-full/claude-managed-settings.json"
    local entry
    for entry in 'Bash(cfwf issue approve*)' 'Bash(cfwf issue unblock*)' 'Bash(cfwf pr unblock*)' \
        mcp__cfwf__issue_approve mcp__cfwf__issue_unblock mcp__cfwf__pr_unblock mcp__cfwf__workflow_status_set; do
        jq -r '.permissions.deny[]' "${settings}" | grep -qxF "${entry}"
    done
    jq -r '.permissions.allow[]' "${settings}" | grep -qxF 'Bash(cfwf *)'
    jq -r '.permissions.allow[]' "${settings}" | grep -qxF 'mcp__cfwf__*'
}

# --- --assign-self refuses an item assigned to another user (#1962) -------------

# Sets the assignees of the pull request EDIT_PR, as the REST read pr edit makes answers it, to the
# logins given (none for no assignee).
set_pr_edit_assignees() {
    local fixture
    fixture="$(api_fixture "repos/${REPO}/pulls/${EDIT_PR}").json"
    jq --args '. + {assignees: ($ARGS.positional | map({login: .}))}' "$@" < "${fixture}" > "${fixture}.next"
    mv "${fixture}.next" "${fixture}"
}

# Sets the assignees of issue EDIT_ISSUE, as gh issue view answers it, to the logins given.
set_issue_edit_assignees() {
    local fixture
    fixture="$(issue_fixture "${EDIT_ISSUE}").json"
    jq --args '. + {assignees: ($ARGS.positional | map({login: .}))}' "$@" < "${fixture}" > "${fixture}.next"
    mv "${fixture}.next" "${fixture}"
}

# Sets the assignees of the pull request SYNC_PR, as gh pr view answers it, to the logins given.
set_sync_assignees() {
    jq --args '. + {assignees: ($ARGS.positional | map({login: .}))}' "$@" < "${GH_FIXTURES}/pr-view.json" > "${GH_FIXTURES}/pr-view.next.json"
    mv "${GH_FIXTURES}/pr-view.next.json" "${GH_FIXTURES}/pr-view.json"
}

@test "pr edit --assign-self assigns an unassigned pull request, and one the agent already holds, in any case beside others (#1962)" {
    prepare_pr_edit
    set_pr_edit_assignees
    run_pr_edit --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-assignee ${AGENT}"

    rm -f "${GH_LOG}"
    set_pr_edit_assignees someone-else "${AGENT^^}"
    run_pr_edit --assign-self
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-assignee ${AGENT}"
}

@test "pr edit --assign-self refuses a pull request assigned to another user with exit 8, writing nothing, not even the title (#1962)" {
    prepare_pr_edit
    set_pr_edit_assignees someone-else
    run_pr_edit --title "${EDIT_TITLE}" --body-file "${TEST_TMP}/edit-body.md" --priority High --assign-self
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: assign refused: already assigned to another user" ]
    [ "$(edits_made)" -eq 0 ]
    [ "$(gh_call_count "label create")" -eq 0 ]

    # Without --assign-self the assignees are no bar to an edit.
    rm -f "${GH_LOG}"
    run_pr_edit --title "${EDIT_TITLE}"
    [ "${status}" -eq 0 ]
    [ "$(edits_made)" -eq 1 ]
}

@test "issue edit --assign-self assigns an unassigned issue, and one the agent already holds beside others (#1962)" {
    prepare_issue_edit
    set_issue_edit_assignees
    run_issue_edit --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --add-assignee ${AGENT}"

    rm -f "${GH_LOG}"
    set_issue_edit_assignees "${AGENT}" someone-else
    run_issue_edit --assign-self
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --add-assignee ${AGENT}"
}

@test "issue edit --assign-self refuses an issue assigned to another user with exit 8, writing nothing (#1962)" {
    prepare_issue_edit
    set_issue_edit_assignees someone-else other-user
    run_issue_edit --title "${EDIT_ISSUE_TITLE}" --body-file "${TEST_TMP}/edit-body.md" --assign-self
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: assign refused: already assigned to another user" ]
    [ "$(issue_edits_made)" -eq 0 ]

    rm -f "${GH_LOG}"
    run_issue_edit --title "${EDIT_ISSUE_TITLE}"
    [ "${status}" -eq 0 ]
    [ "$(issue_edits_made)" -eq 1 ]
}

@test "issue edit dies on an assignee that is not a login, writing nothing (#1962)" {
    prepare_issue_edit
    set_issue_edit_assignees "not a login"
    run_issue_edit --assign-self
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: gh returned an unexpected assignee for ${REPO}"* ]]
    [ "$(issue_edits_made)" -eq 0 ]
}

@test "pr sync-labels --assign-self assigns a pull request that is unassigned or already the agent's (#1962)" {
    write_sync_pr "${REPO} 10"
    write_sync_issue_labels 10 Bug
    write_repository_labels Bug
    write_agent_login
    set_sync_assignees "${AGENT}"
    run_sync_labels --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'Bug\n%s synced' "${SYNC_PR_URL}")" ]
    [ "$(gh_call_count "--add-assignee ${AGENT}")" -eq 1 ]
}

@test "pr sync-labels --assign-self refuses a pull request assigned to another user before adding any label (#1962)" {
    write_sync_pr "${REPO} 10"
    write_sync_issue_labels 10 Bug
    write_repository_labels Bug
    write_agent_login
    set_sync_assignees someone-else
    run_sync_labels --assign-self
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: assign refused: already assigned to another user" ]
    [ "$(gh_call_count " edit ")" -eq 0 ]

    # Without --assign-self the labels are still synced.
    rm -f "${GH_LOG}"
    run_sync_labels
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "--add-label Bug")" -eq 1 ]
}

@test "the help of issue edit, pr edit and pr sync-labels describes the assign refusal (#1962)" {
    local command
    local -a words
    for command in "issue edit" "pr edit" "pr sync-labels"; do
        read -r -a words <<< "${command}"
        run "${SCRIPT}" help "${words[@]}"
        [ "${status}" -eq 0 ]
        [[ "$(printf '%s' "${output}" | tr '\n' ' ' | tr -s ' ')" == *"assigned to another user"* ]]
    done
}
