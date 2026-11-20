#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# Assigned in cfwf_helper.bash. Declared here, which keeps the value, because shellcheck does not
# follow bats `load` and would otherwise read REPO as a misspelling.
declare -g REPO

# --- pr comments and pr reply ---------------------------------------------------

# Writes the page read with the cursors $1 ("" for the first page, -reviews-r2 for the page of
# reviews after r2): the review decision $2 as JSON, then the comments, the reviews and the threads,
# each a discussion_list object, or "" for a list the page was not asked for, which GitHub leaves
# out of its answer.
write_page() {
    jq -n --argjson decision "$2" --arg comments "$3" --arg reviews "$4" --arg threads "$5" \
        '{data: {repository: {pullRequest: ({reviewDecision: $decision}
            + (if $comments == "" then {} else {comments: ($comments | fromjson)} end)
            + (if $reviews == "" then {} else {reviews: ($reviews | fromjson)} end)
            + (if $threads == "" then {} else {reviewThreads: ($threads | fromjson)} end))}}}' \
        > "${GH_FIXTURES}/discussion$1.json"
}

# A pull request whose whole discussion is the one top-level comment with the body $1.
write_one_comment_page() {
    write_page "" null "$(discussion_list 1 false "" "$(issue_comment_node 7 credfeto User "$1")")" "$(empty_list)" "$(empty_list)"
}

run_pr_comments() {
    run --separate-stderr "${SCRIPT}" pr comments --repo "${REPO}" "$@"
}

# The inline comment 500 of pull request 42, which starts its thread, the answer GitHub gives to a
# reply posted to it, and a body to post.
prepare_pr_reply() {
    prepare_pr_comments
    write_inline_comment 500 "" 42
    jq -n --arg url "${DISCUSSION_URL}#discussion_r900" '{id: 900, html_url: $url, in_reply_to_id: 500}' > "${GH_FIXTURES}/reply.json"
    printf 'Fixed in the next commit.\n\nThanks for spotting it.\n' > "${TEST_TMP}/reply.md"
}

# Writes the inline comment $1 as REST gives it: the id it answers ($2, "" for none) and the pull
# request it is on ($3), named as a proxy in front of the API names it.
write_inline_comment() {
    jq -n --argjson id "$1" --arg parent "$2" --arg pull "$3" \
        '{id: $id, in_reply_to_id: (if $parent == "" then null else ($parent | tonumber) end),
          pull_request_url: ("http://api-proxy.example.com/repos/credfeto/credfeto-orchestrator/pulls/" + $pull)}' \
        | write_api "repos/${REPO}/pulls/comments/$1"
}

run_pr_reply() {
    run --separate-stderr "${SCRIPT}" pr reply --repo "${REPO}" "$@"
}

reply_posts() {
    gh_call_count "api --method POST"
}

@test "pr comments and pr reply help describe the format, the exit codes and the retry rule, and call no gh" {
    local flag key
    for flag in --help -h; do
        run "${SCRIPT}" pr comments "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf pr comments --repo <owner/repo> --pr <n>"* ]]
        for key in pr review-decision comment review thread inline in-reply-to author association state created-at \
            submitted-at minimized url resolved outdated path line original-line comments lines; do
            grep -qE "^  ${key} +[^ ]" <<< "${output}" || { echo "no ${key} in the help" >&2; return 1; }
        done
        [[ "${output}" == *"summary comments=<a> reviews=<b> reviews-empty=<c> threads=<d> unresolved=<e> inline=<f>"* ]]
        [[ "${output}" == *"cfwf makes no trust decision"* ]]
        [[ "${output}" == *"each list read to its end."* ]]
        [[ "${output}" == *"when one thread has more than 100 comments, or when one list"*"has more than 100 pages of 100 items."* ]]
        [[ "${output}" == *"line that is not empty and has neither a tab nor a leading \"|\""* ]]
        [[ "${output}" == *"Exit codes: 0 printed; 9 the pull request does not exist (the number of an issue included); 1 a"* ]]
        [[ "${output}" == *"2 a usage error."* ]]

        run "${SCRIPT}" pr reply "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf pr reply --repo <owner/repo> --pr <n> --comment-id <id> --body-file <file|->"* ]]
        [[ "${output}" == *"There is no --body."* ]]
        [[ "${output}" == *"The body is checked for leaks before the comment is read or anything is posted (see 'cfwf help"* ]]
        [[ "${output}" == *"A refused body exits 8"* ]]
        [[ "${output}" == *"It posts once and never tries again. When GitHub refuses the post with HTTP 400, 401, 403, 404,"* ]]
        [[ "${output}" == *"any other HTTP 4xx"*"it says the reply may have been posted"* ]]
        [[ "${output}" == *"do not run it again blindly"* ]]
        [[ "${output}" == *"the same in-reply-to and your own author value (your login, or app/<slug> when you post as an"* ]]
        [[ "${output}" == *"so an inline"*"reply can never be taken for one."* ]]
        [[ "${output}" == *"Exit codes: 0 posted; 8 the body was refused; 9 --comment-id is not an inline review comment"* ]]
    done

    run "${SCRIPT}" help
    [[ "${output}" == *"pr comments "*"(exit 9 when not found)"* ]]
    [[ "${output}" == *"pr reply "*"(exit 8 when the body is refused)"* ]]

    run "${SCRIPT}" help pr
    [[ "${output}" == "Usage: cfwf pr checks "* ]]
    [[ "${output}" == *"Run 'cfwf pr comments --help' for pr comments, which prints a pull request's comments, reviews and"* ]]
    [[ "${output}" == *"Run 'cfwf pr reply --help' for pr reply, which replies to an inline review comment."* ]]
    [[ "${output}" == *"Run 'cfwf pr diff --help' for pr diff, which prints a pull request's diff, changed files or line counts."* ]]

    run "${SCRIPT}" help pr comments
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf pr comments --repo <owner/repo> --pr <n>"* ]]
    run "${SCRIPT}" help pr reply
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf pr reply --repo <owner/repo> --pr <n> --comment-id <id> --body-file <file|->"* ]]
    run "${SCRIPT}" help pr checks
    [[ "${output}" == "Usage: cfwf pr checks "* ]]

    run "${SCRIPT}" help workflow-status
    [[ "${output}" == *"This query (which 'cfwf pr create' also makes,"*"and that of 'cfwf pr comments' are the only places"*"cfwf uses GraphQL, and both only read"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr comments usage errors exit 2 before any gh call" {
    prepare_pr_comments
    local -a cases=("" "--pr 42 --pr 43" "--pr 0" "--pr 000" "--pr x42" "--pr -1" "--pr 42 --issue 3" "--pr 42 --json comments"
        "--pr 42 --jq ." "--pr 42 --template x" "--pr 42 --unresolved" "--pr 42 --comment-id 5" "--pr 42 extra" "--pr")
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_comments ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf pr comments"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr comments --pr 42
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --repo"* ]]

    run_pr_comments --repo "${REPO}" --pr 42
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --repo can only be given once"* ]]

    run_pr_comments
    [[ "${stderr}" == "cfwf: missing required option --pr"* ]]

    run_pr_comments --pr 0
    [[ "${stderr}" == "cfwf: invalid value for --pr: it must be above 0"* ]]

    local stray="gh""p_LEAKMARKER0123456789"
    run_pr_comments --pr 42 "${stray}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 7; its value is not shown)"* && "${stderr}" != *"${stray}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr comments prints the comments, the reviews and each thread with its inline comments, in one read-only call" {
    prepare_pr_comments
    local first second
    first="$(thread_node false false src/run.sh 12 12 \
        "$(inline_node 4220417677 "" 5458415384 credfeto User $'This loop never ends when the list is empty.\n\nSee the guard above.')" \
        "$(inline_node 4220734699 4220417677 5458817077 "" none "Fixed.")")"
    second="$(thread_node true false docs/a.md 3 3 "$(inline_node 4230000001 "" 5458415384 credfeto User "Typo.")")"
    write_page "" '"CHANGES_REQUESTED"' \
        "$(discussion_list 1 false "" "$(issue_comment_node 6057704122 github-actions Bot $'<!-- sarif-summary: 0 -->\nNo findings.')")" \
        "$(discussion_list 2 false "" "$(review_node 5458415384 credfeto User CHANGES_REQUESTED "")" "$(review_node 5458817077 credfeto User COMMENTED $' \n\t\n')")" \
        "$(discussion_list 3 false "" "${first}" "${second}" \
            "$(thread_node false true src/old.sh null 7 "$(inline_node 4230000002 "" 5458817077 credfeto User "Still needed?")")")"

    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected
    expected="$(printf '%s\n' \
        "pr${TAB}${REPO}#42" "review-decision${TAB}CHANGES_REQUESTED" "" \
        "comment${TAB}6057704122" "author${TAB}app/github-actions" "association${TAB}NONE" "created-at${TAB}2026-10-08T10:17:52Z" \
        "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#issuecomment-6057704122" "lines${TAB}2" "| <!-- sarif-summary: 0 -->" "| No findings." "" \
        "review${TAB}5458415384" "author${TAB}credfeto" "association${TAB}OWNER" "state${TAB}CHANGES_REQUESTED" \
        "submitted-at${TAB}2026-10-08T14:44:59Z" "url${TAB}${DISCUSSION_URL}#pullrequestreview-5458415384" "lines${TAB}0" "" \
        "thread${TAB}4220417677" "resolved${TAB}no" "outdated${TAB}no" "path${TAB}src/run.sh" "line${TAB}12" "original-line${TAB}12" "comments${TAB}2" "" \
        "inline${TAB}4220417677" "in-reply-to${TAB}" "review${TAB}5458415384" "author${TAB}credfeto" "association${TAB}OWNER" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4220417677" "lines${TAB}3" \
        "| This loop never ends when the list is empty." "|" "| See the guard above." "" \
        "inline${TAB}4220734699" "in-reply-to${TAB}4220417677" "review${TAB}5458817077" "author${TAB}" "association${TAB}NONE" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4220734699" "lines${TAB}1" "| Fixed." "" \
        "thread${TAB}4230000001" "resolved${TAB}yes" "outdated${TAB}no" "path${TAB}docs/a.md" "line${TAB}3" "original-line${TAB}3" "comments${TAB}1" "" \
        "inline${TAB}4230000001" "in-reply-to${TAB}" "review${TAB}5458415384" "author${TAB}credfeto" "association${TAB}OWNER" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4230000001" "lines${TAB}1" "| Typo." "" \
        "thread${TAB}4230000002" "resolved${TAB}no" "outdated${TAB}yes" "path${TAB}src/old.sh" "line${TAB}" "original-line${TAB}7" "comments${TAB}1" "" \
        "inline${TAB}4230000002" "in-reply-to${TAB}" "review${TAB}5458817077" "author${TAB}credfeto" "association${TAB}OWNER" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4230000002" "lines${TAB}1" "| Still needed?" "" \
        "summary comments=1 reviews=1 reviews-empty=1 threads=3 unresolved=2 inline=4")"
    [ "${output}" = "${expected}" ]

    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    local call
    call="$(cat "${GH_LOG}")"
    [[ "${call}" == "api graphql -f query=query("*" -f o=credfeto -f r=credfeto-orchestrator -F n=42 -F comments=true -F reviews=true -F threads=true --jq "* ]]
    [[ "${call}" != *"--repo"* && "${call}" != *mutation* && "${call}" != *After=* && "${call}" != *"--paginate"* ]]
    [[ "${call}" == *"comments(first:100,after:\$commentsAfter) @include(if:\$comments)"* ]]
    [[ "${call}" == *"reviews(first:100,after:\$reviewsAfter) @include(if:\$reviews)"* ]]
    [[ "${call}" == *"reviewThreads(first:100,after:\$threadsAfter) @include(if:\$threads)"* ]]
}

@test "pr comments prints the first block and a summary of zeros for a pull request nobody has said anything on" {
    prepare_pr_comments
    write_page "" null "$(empty_list)" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 0042
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' "pr${TAB}${REPO}#42" "review-decision${TAB}" "" "summary comments=0 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0")" ]
    [ "$(gh_call_count " -F n=42 ")" -eq 1 ]
}

@test "pr comments prints each review decision as GitHub gives it, and none as an empty value" {
    prepare_pr_comments
    local decision
    for decision in APPROVED CHANGES_REQUESTED REVIEW_REQUIRED; do
        write_page "" "\"${decision}\"" "$(empty_list)" "$(empty_list)" "$(empty_list)"
        run_pr_comments --pr 42
        [ "${status}" -eq 0 ]
        [[ "${output}" == *$'\n'"review-decision${TAB}${decision}"$'\n'* ]]
    done
    write_page "" '"SOMETHING\tNEW\nsummary x"' "$(empty_list)" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 42
    [[ "${output}" == *$'\n'"review-decision${TAB}SOMETHING NEW summary x"$'\n'* ]]
}

@test "pr comments prints a user as the login, a bot as app/slug, any other kind as kind/login and a deleted account as empty" {
    prepare_pr_comments
    write_page "" null \
        "$(discussion_list 5 false "" "$(issue_comment_node 1 credfeto User a)" "$(issue_comment_node 2 credfeto Bot b)" \
            "$(issue_comment_node 3 old-import Mannequin c)" "$(issue_comment_node 4 "" none d)" "$(issue_comment_node 5 acme Organization e)")" \
        "$(discussion_list 1 false "" "$(review_node 6 dependabot Bot APPROVED "")")" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 7 "" 6 copilot Bot f)")")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^author${TAB}" <<< "${output}")" = "$(printf '%s\n' "author${TAB}credfeto" "author${TAB}app/credfeto" "author${TAB}mannequin/old-import" \
        "author${TAB}" "author${TAB}organization/acme" "author${TAB}app/dependabot" "author${TAB}app/copilot")" ]
    [ "$(grep "^association${TAB}" <<< "${output}" | sort -u)" = "$(printf '%s\n' "association${TAB}NONE" "association${TAB}OWNER")" ]
}

@test "pr comments takes every id from fullDatabaseId, so one above 2^31 is whole and is the id pr reply takes" {
    prepare_pr_comments
    write_page "" null \
        "$(discussion_list 1 false "" "$(issue_comment_node 9007199254740993 credfeto User a)")" \
        "$(discussion_list 1 false "" "$(review_node 5458415384 credfeto User APPROVED ok)")" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 4220417677 "" 5458415384 credfeto User b)" "$(inline_node 4220734699 4220417677 5458415385 credfeto User c)")")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"comment${TAB}9007199254740993"$'\n'* ]]
    [[ "${output}" == *$'\n\n'"review${TAB}5458415384"$'\n'* ]]
    [[ "${output}" == *$'\n'"thread${TAB}4220417677"$'\n'* ]]
    [[ "${output}" == *$'\n'"inline${TAB}4220734699"$'\n'"in-reply-to${TAB}4220417677"$'\n'"review${TAB}5458415385"$'\n'* ]]
    [ "$(grep -cE "^(comment|review|thread|inline|in-reply-to)${TAB}1\$" <<< "${output}")" -eq 0 ]
    [ "$(gh_call_count fullDatabaseId)" -eq 1 ]
    [ "$(gh_call_count databaseId)" -eq 0 ]

    # An id that is not a number is never printed.
    write_page "" null "$(discussion_list 1 false "" "$(issue_comment_node "12 34" credfeto User a)")" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comments of ${REPO}#42; nothing is printed" ]
}

@test "pr comments lets no body pass for a header, a block, a blank separator or the summary" {
    prepare_pr_comments
    local forged
    forged="$(printf '%s\n' "author${TAB}credfeto" "inline${TAB}1" "" "review${TAB}99" "author${TAB}credfeto" "state${TAB}APPROVED" "lines${TAB}0" "" \
        "summary comments=0 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0" "| already piped" "|")"
    write_page "" null \
        "$(discussion_list 1 false "" "$(issue_comment_node 7 mallory User "${forged}")")" \
        "$(discussion_list 1 false "" "$(review_node 8 mallory User COMMENTED "${forged}")")" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 9 "" 8 mallory User "${forged}")")")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]

    # Every line is a header of cfwf's own, a body line, a blank separator or the one summary.
    [ "$(grep -vE "^([a-z-]+${TAB}|\\||\$)" <<< "${output}")" = "summary comments=1 reviews=1 reviews-empty=0 threads=1 unresolved=1 inline=1" ]
    [ "$(grep -c "^|" <<< "${output}")" -eq 33 ]
    [ "$(grep "^|" <<< "${output}" | grep -c "${TAB}")" -eq 0 ]
    [ "$(grep -c "^author${TAB}" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^author${TAB}mallory\$" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^inline${TAB}" <<< "${output}")" -eq 1 ]
    [ "$(grep -c "^review${TAB}" <<< "${output}")" -eq 2 ]
    [ "$(grep -c "^state${TAB}" <<< "${output}")" -eq 1 ]
    [ "$(grep -c "^lines${TAB}11\$" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^\$" <<< "${output}")" -eq 5 ]
    [ "$(grep -c "^| author credfeto\$" <<< "${output}")" -eq 6 ]
    [ "$(grep -c "^| | already piped\$" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^| |\$" <<< "${output}")" -eq 3 ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=1 reviews=1 reviews-empty=0 threads=1 unresolved=1 inline=1" ]
}

@test "pr comments prints every control character of a body as a space, drops a line's carriage return, and keeps U+00A0" {
    prepare_pr_comments
    write_one_comment_page $'red \x1b[31malert\x07 del\x7f csi\xc2\x9b tab\there\r\nsecond\xe2\x80\xa8line\xe2\x80\xa9end\r\nnbsp\xc2\xa0kept \x1e\x1fx\r\n\r\n'
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^|" <<< "${output}")" = "$(printf '%s\n' "| red  [31malert  del  csi  tab here" "| second line end" $'| nbsp\xc2\xa0kept   x')" ]
    [[ "${output}" == *$'\n'"lines${TAB}3"$'\n'* ]]
    [ "$(LC_ALL=C grep -c $'[\x01-\x08\x0b-\x1f\x7f]' <<< "${output}")" -eq 0 ]
    [ "$(LC_ALL=C grep -c $'\xc2\x9b\\|\xe2\x80\xa8\\|\xe2\x80\xa9' <<< "${output}")" -eq 0 ]
}

@test "pr comments keeps a path, a login, a state and a URL with control characters or Unicode line ends on one line each" {
    prepare_pr_comments
    local review thread
    review="$(review_node 8 $'mal\nlory\x1b[2J' User APPROVED ok | jq '.state = "APPROVED\nstate\tFORGED\u0000" | .url = "https://example.com/\n\nsummary x"')"
    thread="$(thread_node false false $'src/a\tb\n\nsummary comments=0\x1e\x1f.sh\xe2\x80\xa8author\tcredfeto\xe2\x80\xa9summary x' 1 1 "$(inline_node 9 "" 8 $'bot\tname\xe2\x80\xa8' Bot ok)")"
    write_page "" null "$(empty_list)" "$(discussion_list 1 false "" "${review}")" "$(discussion_list 1 false "" "${thread}")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"author${TAB}mal lory [2J"$'\n'"association${TAB}OWNER"$'\n'"state${TAB}APPROVED state FORGED "$'\n'* ]]
    [[ "${output}" == *$'\n'"url${TAB}https://example.com/  summary x"$'\n'* ]]
    [[ "${output}" == *$'\n'"path${TAB}src/a b  summary comments=0  .sh author credfeto summary x"$'\n'* ]]
    [[ "${output}" == *$'\n'"author${TAB}app/bot name "$'\n'* ]]
    [ "$(LC_ALL=C grep -c $'\xe2\x80\xa8\\|\xe2\x80\xa9' <<< "${output}")" -eq 0 ]
    [ "$(grep -vE "^([a-z-]+${TAB}[^${TAB}]*|\\|.*|)\$" <<< "${output}")" = "summary comments=0 reviews=1 reviews-empty=0 threads=1 unresolved=1 inline=1" ]
    [ "$(wc -l <<< "${output}")" -eq 32 ]
}

@test "pr comments counts the body lines it prints: none for an empty body or one of blank lines only" {
    prepare_pr_comments
    local -a bodies=("" "one line" $'ends in newlines\n\n\n\n' $'\n\n\n' $'\r\n\r\n' $'a\n\n\nb\n' $'  \n \n' $'\n\nleading blank lines')
    local -a counts=(0 1 1 0 0 4 2 3)
    local index
    for index in "${!bodies[@]}"; do
        write_one_comment_page "${bodies[index]}"
        run_pr_comments --pr 42
        [ "${status}" -eq 0 ]
        [[ "${output}" == *$'\n'"lines${TAB}${counts[index]}"$'\n'* ]] || { echo "body ${index}: ${output}" >&2; return 1; }
        [ "$(grep -c "^|" <<< "${output}")" -eq "${counts[index]}" ]
    done
    # A body GitHub leaves out altogether is an empty one.
    write_page "" null "$(discussion_list 1 false "" "$(issue_comment_node 7 credfeto User x | jq 'del(.body) | .isMinimized = true')")" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"minimized${TAB}yes"$'\n'*$'\n'"lines${TAB}0"$'\n\n'"summary "* ]]
}

@test "pr comments prints a review with a body or a state of its own, and only counts the blank COMMENTED wrapper" {
    prepare_pr_comments
    write_page "" null "$(empty_list)" \
        "$(discussion_list 5 false "" "$(review_node 1 credfeto User COMMENTED "")" "$(review_node 2 credfeto User COMMENTED "A remark.")" \
            "$(review_node 3 credfeto User APPROVED "")" "$(review_node 4 credfeto User DISMISSED $'\n')" \
            "$(review_node 5 credfeto User PENDING "" | jq '.submittedAt = null | del(.body)')")" \
        "$(empty_list)"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^review${TAB}" <<< "${output}")" = "$(printf '%s\n' "review${TAB}2" "review${TAB}3" "review${TAB}4" "review${TAB}5")" ]
    [[ "${output}" == *$'\n'"state${TAB}PENDING"$'\n'"submitted-at${TAB}"$'\n'* ]]
    [ "$(tail -1 <<< "${output}")" = "summary comments=0 reviews=4 reviews-empty=1 threads=0 unresolved=0 inline=0" ]
}

@test "pr comments reads each list to its last page, asking each later page for that list alone" {
    prepare_pr_comments
    local list pages
    for list in comments reviews threads; do
        for pages in 2 3; do
            rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
            local -a first=("$(empty_list)" "$(empty_list)" "$(empty_list)") second=("" "" "") third=("" "" "")
            local total="${pages}" more_after_second=false
            [ "${pages}" -eq 2 ] || more_after_second=true
            case "${list}" in
                comments)
                    first[0]="$(discussion_list "${total}" true p2 "$(issue_comment_node 1 credfeto User one)")"
                    second[0]="$(discussion_list "${total}" "${more_after_second}" p3 "$(issue_comment_node 2 credfeto User two)")"
                    third[0]="$(discussion_list "${total}" false "" "$(issue_comment_node 3 credfeto User three)")"
                    ;;
                reviews)
                    first[1]="$(discussion_list "${total}" true p2 "$(review_node 1 credfeto User APPROVED one)")"
                    second[1]="$(discussion_list "${total}" "${more_after_second}" p3 "$(review_node 2 credfeto User APPROVED two)")"
                    third[1]="$(discussion_list "${total}" false "" "$(review_node 3 credfeto User APPROVED three)")"
                    ;;
                threads)
                    first[2]="$(discussion_list "${total}" true p2 "$(thread_node true false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)")")"
                    second[2]="$(discussion_list "${total}" "${more_after_second}" p3 "$(thread_node true false a.sh 2 2 "$(inline_node 2 "" 9 credfeto User two)")")"
                    third[2]="$(discussion_list "${total}" false "" "$(thread_node true false a.sh 3 3 "$(inline_node 3 "" 9 credfeto User three)")")"
                    ;;
            esac
            write_page "" null "${first[@]}"
            write_page "-${list}-p2" null "${second[@]}"
            write_page "-${list}-p3" null "${third[@]}"

            run_pr_comments --pr 42
            [ "${status}" -eq 0 ] || { echo "${list} over ${pages} pages: ${stderr}" >&2; return 1; }
            [ -z "${stderr}" ]
            [ "$(grep "^|" <<< "${output}")" = "$(printf '%s\n' "| one" "| two" "| three" | head -"${pages}")" ]
            [ "$(grep -c "^lines${TAB}" <<< "${output}")" -eq "${pages}" ]
            [ "$(wc -l < "${GH_LOG}")" -eq "${pages}" ]

            local -a later=("-F comments=false" "-F reviews=false" "-F threads=false")
            local -A position=([comments]=0 [reviews]=1 [threads]=2)
            later[${position[${list}]}]="-F ${list}=true -f ${list}After=p2"
            [ "$(sed -n 2p "${GH_LOG}" | grep -cF -- " -F n=42 ${later[*]} --jq ")" -eq 1 ]
            [ "$(gh_call_count "After=")" -eq "$((pages - 1))" ]
            [ "$(gh_call_count "After=p3")" -eq "$((pages - 2))" ]
        done
    done
}

@test "pr comments pages all three lists at once, each with its own cursor, and prints every item once in order" {
    prepare_pr_comments
    write_page "" '"APPROVED"' \
        "$(discussion_list 2 true c2 "$(issue_comment_node 1 credfeto User "comment one")")" \
        "$(discussion_list 3 true r2 "$(review_node 11 credfeto User APPROVED "review one")")" \
        "$(discussion_list 2 true t2 "$(thread_node false false a.sh 1 1 "$(inline_node 21 "" 11 credfeto User "inline one")")")"
    write_page "-comments-c2-reviews-r2-threads-t2" '"APPROVED"' \
        "$(discussion_list 2 false "" "$(issue_comment_node 2 credfeto User "comment two")")" \
        "$(discussion_list 3 true r3 "$(review_node 12 credfeto User COMMENTED "")")" \
        "$(discussion_list 2 false "" "$(thread_node true false a.sh 2 2 "$(inline_node 22 "" 12 credfeto User "inline two")")")"
    write_page "-reviews-r3" '"CHANGES_REQUESTED"' "" "$(discussion_list 3 false "" "$(review_node 13 credfeto User APPROVED "review three")")" ""

    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^|" <<< "${output}")" = "$(printf '%s\n' "| comment one" "| comment two" "| review one" "| review three" "| inline one" "| inline two")" ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=2 reviews=2 reviews-empty=1 threads=2 unresolved=1 inline=2" ]
    # The decision printed is the one read last.
    [[ "${output}" == *$'\n'"review-decision${TAB}CHANGES_REQUESTED"$'\n'* ]]
    [ "$(wc -l < "${GH_LOG}")" -eq 3 ]
    [ "$(sed -n 2p "${GH_LOG}" | grep -cF -- "-F comments=true -f commentsAfter=c2 -F reviews=true -f reviewsAfter=r2 -F threads=true -f threadsAfter=t2 --jq")" -eq 1 ]
    [ "$(sed -n 3p "${GH_LOG}" | grep -cF -- "-F comments=false -F reviews=true -f reviewsAfter=r3 -F threads=false --jq")" -eq 1 ]
    [ "$(gh_call_count mutation)" -eq 0 ]
}

@test "pr comments prints nothing when a list is shorter than GitHub's count of it, or a page lost a block" {
    prepare_pr_comments
    local list
    local -a lists nodes=("$(issue_comment_node 1 credfeto User one)" "$(review_node 1 credfeto User APPROVED one)"
        "$(thread_node false false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)")")
    for list in 0 1 2; do
        lists=("$(empty_list)" "$(empty_list)" "$(empty_list)")
        lists[list]="$(discussion_list 2 false "" "${nodes[list]}")"
        write_page "" null "${lists[@]}"
        run_pr_comments --pr 42
        [ "${status}" -eq 1 ] || { echo "list ${list}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the comments of ${REPO}#42 changed or were cut short while they were read; nothing is printed" ]
    done

    # A list that grew while it was read is whole when the items gathered match the last count.
    write_page "" null "$(discussion_list 1 true c2 "$(issue_comment_node 1 credfeto User one)")" "$(empty_list)" "$(empty_list)"
    write_page "-comments-c2" null "$(discussion_list 2 false "" "$(issue_comment_node 2 credfeto User two)")" "" ""
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=2 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0" ]

    # The page says it held two comments and only one block arrived.
    local row=$'\x1e' sep=$'\x1f'
    printf '%s\n' "${row}comment${sep}1" "comment${TAB}1" "lines${TAB}0" \
        "${row}page${sep}${sep}2${sep}2${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end" > "${GH_FIXTURES}/discussion.raw"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the comments of ${REPO}#42 changed or were cut short while they were read; nothing is printed" ]

    # A thread whose own count is above the inline comments it came with, and one that lost a block.
    rm "${GH_FIXTURES}/discussion.raw"
    write_page "" null "$(empty_list)" "$(empty_list)" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)" | jq '.comments.totalCount = 2')")"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"changed or were cut short"* ]]

    printf '%s\n' "${row}thread${sep}false${sep}2${sep}2${sep}no${sep}1" "thread${TAB}1" "${row}inline${sep}${sep}9${sep}1" "inline${TAB}1" \
        "${row}page${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}1${sep}1${sep}false${sep}${sep}end" > "${GH_FIXTURES}/discussion.raw"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"changed or were cut short"* ]]
}

@test "pr comments refuses an answer that is not the pages it asked for, printing nothing" {
    prepare_pr_comments
    local row=$'\x1e' sep=$'\x1f'
    local closed="0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}"
    local page="${row}page${sep}${sep}${closed}${sep}end"
    # A page that says it held one thread, and that thread with its one inline comment.
    local thread_page="${row}page${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}1${sep}1${sep}false${sep}${sep}end"
    local thread="${row}thread${sep}false${sep}1${sep}1${sep}no${sep}1"$'\n'"thread${TAB}1"
    local -a answers=(
        "a line before any block"$'\n'"${page}"
        "${row}comment${sep}1"$'\n'"comment${TAB}1"
        "${row}comment${sep}1"$'\n'"${row}page${sep}${sep}${closed}"
        "${row}issue${sep}1"$'\n'"${page}"
        "${row}"$'\n'"${page}"
        "${row}comment${sep}x1"$'\n'"${page}"
        "${row}inline${sep}${sep}9${sep}1"$'\n'"${page}"
        "${row}thread${sep}false${sep}1${sep}1${sep}no${sep}1"$'\n'"${row}inline${sep}x${sep}9${sep}1"$'\n'"${page}"
        "${row}thread${sep}maybe${sep}1${sep}1${sep}no${sep}1"$'\n'"${page}"
        "${row}thread${sep}false${sep}many${sep}1${sep}no${sep}1"$'\n'"${page}"
        "${row}thread${sep}false${sep}1${sep}x${sep}no${sep}1"$'\n'"${thread_page}"
        # An inline comment with no id of its own, which read gives one field fewer, and rows with a field too many.
        "${thread}"$'\n'"${row}inline${sep}${sep}9${sep}"$'\n'"inline${TAB}"$'\n'"${thread_page}"
        "${thread}"$'\n'"${row}inline${sep}${sep}9${sep}1${sep}2"$'\n'"inline${TAB}2"$'\n'"${thread_page}"
        "${thread}"$'\n'"${row}inline${sep}${sep}x${sep}1"$'\n'"inline${TAB}1"$'\n'"${thread_page}"
        "${row}thread${sep}false${sep}0${sep}0${sep}no${sep}"$'\n'"${thread_page}"
        "${row}comment${sep}1${sep}2"$'\n'"${page}"
        "${row}page${sep}${sep}0${sep}x${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end"
        "${row}page${sep}${sep}${closed}${sep}fin"
        "${row}page${sep}${sep}none${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end"
        "${row}page${sep}${sep}0${sep}0${sep}perhaps${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end"
        ""
    )
    local answer
    for answer in "${answers[@]}"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/discussion.raw"
        run_pr_comments --pr 42
        [ "${status}" -eq 1 ] || { echo "accepted: ${answer}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comments of ${REPO}#42; nothing is printed" ]
    done

    # The same thread with its inline comment whole is printed, so each answer above was refused for what it lacks.
    printf '%s\n' "${thread}" "${row}inline${sep}${sep}9${sep}1" "inline${TAB}1" "${thread_page}" > "${GH_FIXTURES}/discussion.raw"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=0 reviews=0 reviews-empty=0 threads=1 unresolved=1 inline=1" ]

    # An answer with no pull request in it, were gh ever to give one without an error.
    rm "${GH_FIXTURES}/discussion.raw"
    jq -n '{data: {repository: {pullRequest: null}}}' > "${GH_FIXTURES}/discussion.json"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"unexpected answer"* ]]
}

@test "pr comments stops on a cursor that repeats, a cursor it would not send, and a list of more than 100 pages" {
    prepare_pr_comments
    write_page "" null "$(empty_list)" "$(discussion_list 3 true r2 "$(review_node 1 credfeto User APPROVED one)")" "$(empty_list)"
    write_page "-reviews-r2" null "" "$(discussion_list 3 true r2 "$(review_node 2 credfeto User APPROVED two)")" ""
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: GitHub returned the same page of the reviews of ${REPO}#42 twice; nothing is printed" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]

    local cursor
    for cursor in 'a b' 'a"b' 'a,b' '@file' 'a%b' ""; do
        rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
        write_page "" null "$(empty_list)" "$(empty_list)" "$(discussion_list 3 true "${cursor}" "$(thread_node true false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)")")"
        run_pr_comments --pr 42
        [ "${status}" -eq 1 ] || { echo "cursor '${cursor}' was sent" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"unexpected answer"* ]]
        [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    done

    # GitHub's cursors are base64, and one with every character of that alphabet is sent as it is.
    rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
    write_page "" null "$(discussion_list 1 true "Y3Vy+c29y_Onb-yOpHP=" )" "$(empty_list)" "$(empty_list)"
    write_page "-comments-Y3Vy+c29y_Onb-yOpHP=" null "$(discussion_list 1 false "" "$(issue_comment_node 1 credfeto User one)")" "" ""
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "-f commentsAfter=Y3Vy+c29y_Onb-yOpHP= ")" -eq 1 ]

    rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
    local page
    write_page "" null "$(discussion_list 0 true c1)" "$(empty_list)" "$(empty_list)"
    for page in {1..99}; do
        printf '{"data":{"repository":{"pullRequest":{"reviewDecision":null,"comments":{"totalCount":0,"pageInfo":{"hasNextPage":true,"endCursor":"c%s"},"nodes":[]}}}}}\n' \
            "$((page + 1))" > "${GH_FIXTURES}/discussion-comments-c${page}.json"
    done
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the comments of ${REPO}#42 run to more than 100 pages; nothing is printed" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 100 ]
}

@test "pr comments refuses a thread with more comments than one page holds, naming it, and prints nothing" {
    prepare_pr_comments
    write_page "" null \
        "$(discussion_list 1 false "" "$(issue_comment_node 1 credfeto User one)")" "$(empty_list)" \
        "$(discussion_list 2 false "" "$(thread_node true false a.sh 1 1 "$(inline_node 21 "" 9 credfeto User one)")" \
            "$(thread_node false false b.sh 1 1 "$(inline_node 4220417677 "" 9 credfeto User two)" | jq '.comments.pageInfo.hasNextPage = true | .comments.totalCount = 101')")"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the thread that starts with the inline comment 4220417677 of ${REPO}#42 has more than 100 comments, which cfwf cannot read; nothing is printed" ]
}

@test "pr comments prints nothing, never part of a list, when a later page fails" {
    prepare_pr_comments
    write_page "" null "$(discussion_list 2 true c2 "$(issue_comment_node 1 credfeto User one)")" "$(empty_list)" "$(empty_list)"
    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/discussion-comments-c2.fail"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: gh: Bad Gateway (HTTP 502)" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
}

@test "pr comments exits 9 for a number that is not a pull request, and 1 for any other failed read" {
    prepare_pr_comments
    local number
    for number in 999999 1499; do
        printf 'gh: Could not resolve to a PullRequest with the number of %s.\n' "${number}" > "${GH_FIXTURES}/discussion.fail"
        printf '{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND"}]}' > "${GH_FIXTURES}/discussion.failout"
        run_pr_comments --pr "${number}"
        [ "${status}" -eq 9 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the pull request ${REPO}#${number} was not found" ]
    done

    printf "gh: Could not resolve to a Repository with the name 'credfeto/credfeto-orchestrator'.\n" > "${GH_FIXTURES}/discussion.fail"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: gh: Could not resolve to a Repository with the name 'credfeto/credfeto-orchestrator'." ]

    # The words of GitHub's not-found answer in what gh printed, a comment's body say, are not that answer.
    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/discussion.fail"
    printf '{"body":"Could not resolve to a PullRequest with the number of 42."}' > "${GH_FIXTURES}/discussion.failout"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: gh: Bad Gateway (HTTP 502)" ]

    printf 'connection reset \x1b[31mby peer\nsecond line\n' > "${GH_FIXTURES}/discussion.fail"
    rm "${GH_FIXTURES}/discussion.failout"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: connection reset [31mby peer" ]
}

@test "pr comments never lets what gh writes to stderr on a successful read reach its output, and leaves no temporary file" {
    prepare_pr_comments
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"
    write_one_comment_page "A comment."
    printf 'warning: a newer gh is available\nsummary comments=9\n' > "${GH_FIXTURES}/discussion.stderr"
    TMPDIR="${scratch}" run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [[ "${output}" != *"newer gh"* ]]
    [ "$(tail -1 <<< "${output}")" = "summary comments=1 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0" ]
    [ -z "$(ls -A "${scratch}")" ]
}

@test "pr reply usage errors exit 2 before any gh call" {
    prepare_pr_reply
    local body="${TEST_TMP}/reply.md"
    local -a cases=(
        "--pr 42 --comment-id 500"
        "--pr 42 --body-file ${body}"
        "--comment-id 500 --body-file ${body}"
        "--pr 42 --pr 43 --comment-id 500 --body-file ${body}"
        "--pr 42 --comment-id 500 --comment-id 501 --body-file ${body}"
        "--pr 42 --comment-id 500 --body-file ${body} --body-file ${body}"
        "--pr 0 --comment-id 500 --body-file ${body}"
        "--pr 42 --comment-id 50a --body-file ${body}"
        "--pr 42 --comment-id -500 --body-file ${body}"
        "--pr 42 --comment-id +500 --body-file ${body}"
        "--pr 42 --comment-id 0 --body-file ${body}"
        "--pr 42 --comment-id 000 --body-file ${body}"
        "--pr 42 --comment-id 12345678901234567890 --body-file ${body}"
        "--pr 42 --comment-id 500 --body text"
        "--pr 42 --comment-id 500 --body-file ${body} --sha ${HEAD_SHA}"
        "--pr 42 --comment-id 500 --body-file"
    )
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_reply ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf pr reply"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr reply --pr 42 --comment-id 500 --body-file "${body}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --repo"* ]]

    run_pr_reply --repo "${REPO}" --pr 42 --comment-id 500 --body-file "${body}"
    [[ "${stderr}" == "cfwf: --repo can only be given once"* ]]
    run_pr_reply --pr 42 --body-file "${body}"
    [[ "${stderr}" == "cfwf: missing required option --comment-id"* ]]
    run_pr_reply --pr 42 --comment-id 500
    [[ "${stderr}" == "cfwf: missing required option --body-file"* ]]
    run_pr_reply --pr 42 --comment-id 12345678901234567890 --body-file "${body}"
    [[ "${stderr}" == "cfwf: invalid value for --comment-id: it must be a number of at most 19 digits"* ]]
    run_pr_reply --pr 42 --comment-id 0 --body-file "${body}"
    [[ "${stderr}" == "cfwf: invalid value for --comment-id: it must be above 0"* ]]

    local stray="gh""p_LEAKMARKER0123456789"
    run_pr_reply --pr 42 --comment-id 500 --body "${stray}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 9; its value is not shown)"* && "${stderr}" != *"${stray}"* ]]
    run_pr_reply --pr 42 --comment-id 500 --body-file "${body}" "${stray}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 11; its value is not shown)"* && "${stderr}" != *"${stray}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr reply reads the comment, posts the body once to the thread's first comment and prints the new comment" {
    prepare_pr_reply
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(printf '%s\n' "inline${TAB}900" "in-reply-to${TAB}500" "url${TAB}${DISCUSSION_URL}#discussion_r900")" ]
    cmp "${TEST_TMP}/reply.md" "${GH_FIXTURES}/reply-body.txt"

    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [[ "$(sed -n 1p "${GH_LOG}")" == "api repos/${REPO}/pulls/comments/500 --jq "* ]]
    [[ "$(sed -n 2p "${GH_LOG}")" == "api --method POST repos/${REPO}/pulls/42/comments/500/replies -F body=@"*" --jq "* ]]
    [ "$(grep -c -- "--repo\|in_reply_to=\|-f body=\|${TEST_TMP}/reply.md\|Fixed in the next commit" "${GH_LOG}")" -eq 0 ]
}

@test "pr reply posts to the thread's first comment when the id is that of a reply, and drops leading zeros" {
    prepare_pr_reply
    write_inline_comment 501 500 42
    run_pr_reply --pr 0042 --comment-id 000501 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' "inline${TAB}900" "in-reply-to${TAB}500" "url${TAB}${DISCUSSION_URL}#discussion_r900")" ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/comments/501 ")" -eq 1 ]
    [ "$(gh_call_count "api --method POST repos/${REPO}/pulls/42/comments/500/replies ")" -eq 1 ]
    [ "$(reply_posts)" -eq 1 ]
}

@test "pr reply exits 9 without posting for an id that is not an inline comment of that pull request" {
    prepare_pr_reply
    run_pr_reply --pr 42 --comment-id 777 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the comment 777 is not an inline review comment of ${REPO}#42" ]
    [ "$(reply_posts)" -eq 0 ]

    # The same comment on another pull request of the repository, and on one whose number only ends alike.
    local pull
    for pull in 43 142 4; do
        write_inline_comment 500 "" "${pull}"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 9 ] || { echo "pull ${pull}: ${status}" >&2; return 1; }
        [ "${stderr}" = "cfwf: the comment 500 is not an inline review comment of ${REPO}#42" ]
    done
    [ "$(reply_posts)" -eq 0 ]

    # The host and the repository in the comment's own URL are not compared: a proxy answers with its own.
    jq -n '{id: 500, in_reply_to_id: null, pull_request_url: "https://api.github.com/repos/renamed-owner/renamed/pulls/42"}' | write_api "repos/${REPO}/pulls/comments/500"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ "$(reply_posts)" -eq 1 ]
}

@test "pr reply fails without posting when the comment cannot be read or the answer is not that comment" {
    prepare_pr_reply
    fail_api "repos/${REPO}/pulls/comments/500"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comment 500 of ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    rm "$(api_fixture "repos/${REPO}/pulls/comments/500").fail"
    local answer
    for answer in '{id: 501, in_reply_to_id: null, pull_request_url: "x/pulls/42"}' '{id: 500, in_reply_to_id: "abc", pull_request_url: "x/pulls/42"}' '{}'; do
        jq -n "${answer}" | write_api "repos/${REPO}/pulls/comments/500"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ] || { echo "accepted: ${answer}" >&2; return 1; }
        [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comment 500 of ${REPO}" ]
    done
    # An answer cut short before its last field, which read would otherwise take as a comment of this pull request.
    printf '500\x1f\x1fx/pulls/42\n' > "$(api_fixture "repos/${REPO}/pulls/comments/500").raw"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comment 500 of ${REPO}" ]
    [ "$(reply_posts)" -eq 0 ]
}

@test "pr reply reads the body from stdin, posts the copy it checked, and leaves no temporary file" {
    prepare_pr_reply
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"
    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file - <<< "A reply from stdin"
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/reply-body.txt")" = "A reply from stdin" ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ -z "$(ls -A "${scratch}")" ]

    printf 'A line.\n/tmp/leak\n' > "${TEST_TMP}/leak.md"
    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 8 ]
    [ -z "$(ls -A "${scratch}")" ]

    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/reply.fail"
    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
    rm "${GH_FIXTURES}/reply.fail"

    # The body file is rewritten by the read of the comment, after the check: what is posted is the copy.
    cp "${TEST_TMP}/reply.md" "${TEST_TMP}/checked.md"
    printf '%s\n' "${TEST_TMP}/reply.md" > "${GH_FIXTURES}/rewrite"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [[ "$(cat "${TEST_TMP}/reply.md")" == rewritten* ]]
    cmp "${TEST_TMP}/checked.md" "${GH_FIXTURES}/reply-body.txt"
}

@test "pr reply refuses a leaking body with exit 8, naming the rule and line only, before reading or posting anything" {
    prepare_pr_reply
    local token
    token="$(leak_tokens | head -1)"
    local -a leaks=("${token}" "see /home/someone/notes" $'a bell \x07 here' $'bad \xff byte')
    local -a rules=("token" "host path" "control character" "invalid UTF-8")
    local index
    for index in "${!leaks[@]}"; do
        write_leak_body "${leaks[index]}"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/leak.md"
        assert_refused "${status}" "${output}" "${stderr}" "${rules[index]}" "${leaks[index]}"
    done

    printf 'x%.0s' {1..65537} > "${TEST_TMP}/long.md"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/long.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: too long" ]
    [ ! -f "${GH_LOG}" ]

    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/secret-plans PRIVATE
    write_leak_body "As in credfeto/secret-plans#5."
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/leak.md"
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "secret-plans"
    [ "$(gh_call_count "api ")" -eq 0 ]

    # A body of exactly the limit is posted.
    printf 'x%.0s' {1..65536} > "${TEST_TMP}/long.md"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/long.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/long.md" "${GH_FIXTURES}/reply-body.txt"
}

@test "pr reply refuses a body of only U+3000, U+00A0, U+200B or U+FEFF as empty, never echoing it, and posts one with a visible character" {
    prepare_pr_reply
    write_invisible_bodies
    local name
    for name in "${INVISIBLE_BODIES[@]}"; do
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/invisible-${name}.md"
        [ "${status}" -eq 1 ] || { echo "took ${name}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the body is empty" ] || { echo "wrong message for ${name}" >&2; return 1; }
    done
    [ ! -f "${GH_LOG}" ]

    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/visible-among-invisible.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/visible-among-invisible.md" "${GH_FIXTURES}/reply-body.txt"
}

@test "pr reply refuses a blank, missing or unreadable body as a runtime failure, without calling gh" {
    prepare_pr_reply
    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]

    local path
    for path in "${TEST_TMP}/nope.md" "${TEST_TMP}"; do
        run_pr_reply --pr 42 --comment-id 500 --body-file "${path}"
        [ "${status}" -eq 1 ]
        [ "${stderr}" = "cfwf: cannot read the --body-file" ]
    done
    [ -z "${output}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr reply posts a body holding a plan sign-off keyword: only an issue's top-level comments are read for one" {
    prepare_pr_reply
    local keyword
    while IFS= read -r keyword; do
        printf 'Looks right to me: %s.\n\n%s\n' "${keyword}" "${keyword}" > "${TEST_TMP}/reply.md"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 0 ]
        cmp "${TEST_TMP}/reply.md" "${GH_FIXTURES}/reply-body.txt"
    done < <(sign_off_keywords)
    [ "$(reply_posts)" -eq 2 ]
}

@test "pr reply never posts twice: a status that refuses the post says not posted, and any other failure that it may have been posted" {
    prepare_pr_reply
    local error
    for error in "gh: Validation Failed (HTTP 422)" "gh: Not Found (HTTP 404)" "gh: Resource not accessible by integration (HTTP 403)" \
        "gh: Problems parsing JSON (HTTP 400)" "gh: Bad credentials (HTTP 401)" "gh: Gone (HTTP 410)"; do
        : > "${GH_LOG}"
        printf '%s\n' "${error}" > "${GH_FIXTURES}/reply.fail"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the reply was not posted: ${error}" ]
        [ "$(reply_posts)" -eq 1 ]
    done

    local check="run 'cfwf pr comments' and look for it in the thread before posting again"
    # Any other status, the rest of 4xx included, and a refusing status that is not how the line ends.
    for error in "gh: Bad Gateway (HTTP 502)" "Post \"https://api.github.com/x\": context deadline exceeded" "said HTTP 422 somewhere, with no status of its own" \
        "gh: Request Timeout (HTTP 408)" "gh: Conflict (HTTP 409)" "gh: Too Many Requests (HTTP 429)" "gh: Unavailable For Legal Reasons (HTTP 451)" \
        "gh: HTTP 404" "gh: the proxy said (HTTP 422) and went on" "gh: Not Found (HTTP 4040)" "gh: Server Error (HTTP 5422)"; do
        : > "${GH_LOG}"
        printf '%s\n' "${error}" > "${GH_FIXTURES}/reply.fail"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the reply may have been posted (${error}); ${check}" ]
        [ "$(reply_posts)" -eq 1 ]
    done

    # A refusing status on a later line of gh's error is not the answer to the post.
    : > "${GH_LOG}"
    printf 'gh: Bad Gateway (HTTP 502)\ngh: Validation Failed (HTTP 422)\n' > "${GH_FIXTURES}/reply.fail"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the reply may have been posted (gh: Bad Gateway (HTTP 502)); ${check}" ]
    [ "$(reply_posts)" -eq 1 ]

    : > "${GH_LOG}"
    : > "${GH_FIXTURES}/reply.fail"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the reply may have been posted (gh gave no error text); ${check}" ]
    [ "$(reply_posts)" -eq 1 ]
    rm "${GH_FIXTURES}/reply.fail"

    # gh said it worked, with an answer that is not the new comment.
    local answer
    for answer in "" "not a comment" $'900\x1fhttp://github.com/o/r/pull/42#discussion_r900\x1fend' $'900\x1fhttps://github.com/o/r/pull/43#discussion_r900\x1fend' \
        $'900\x1fhttps://github.com/o/r/pull/42#discussion_r901\x1fend' $'9x\x1fhttps://github.com/o/r/pull/42#discussion_r9x\x1fend' \
        $'900\x1fhttps://github.com/o/r/pull/42#discussion_r900 and more\x1fend' $'900\x1fhttps://github.com/o/r/pull/42#discussion_r900'; do
        : > "${GH_LOG}"
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/reply.raw"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ] || { echo "accepted: ${answer}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the reply may have been posted (gh returned an unexpected answer); ${check}" ]
        [ "$(reply_posts)" -eq 1 ]
    done
    rm "${GH_FIXTURES}/reply.raw"

    # A renamed repository, or a proxy with its own host, answers with another host and name.
    jq -n '{id: 901, html_url: "https://github.example.com:8443/new-owner/new.name/pull/42#discussion_r901"}' > "${GH_FIXTURES}/reply.json"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' "inline${TAB}901" "in-reply-to${TAB}500" "url${TAB}https://github.example.com:8443/new-owner/new.name/pull/42#discussion_r901")" ]
}

# --- pr review-comment (#1631) ----------------------------------------------------

REVIEW_COMMENT_USAGE="Usage: cfwf pr review-comment --repo <owner/repo> --pr <n> --path <file> --line <n> [--start-line <n>] [--side RIGHT|LEFT] --body-file <file|->"
REVIEW_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"

# Pull request 42 as REST gives it, with REVIEW_HEAD_SHA as its head, the answer GitHub gives to a
# new inline comment posted on it, and a body to post. It uses the gh stand-in of pr comments.
prepare_review_comment() {
    prepare_pr_comments
    jq -n --arg sha "${REVIEW_HEAD_SHA}" '{number: 42, head: {sha: $sha, ref: "feat/x"}, base: {sha: "f00", ref: "main"}}' \
        | write_api "repos/${REPO}/pulls/42"
    jq -n --arg url "${DISCUSSION_URL}#discussion_r901" '{id: 901, html_url: $url, path: "src/app.sh", line: 12}' > "${GH_FIXTURES}/review-comment.json"
    printf 'This branch never closes the file.\n\n> quoted from the diff\n' > "${TEST_TMP}/review.md"
}

run_review_comment() {
    run --separate-stderr "${SCRIPT}" pr review-comment --repo "${REPO}" --pr 42 --path src/app.sh "$@"
}

review_comment_posts() {
    gh_call_count "api --method POST"
}

# The start of the logged POST, up to the body, for the fields $1 (after commit_id and path).
review_comment_post() {
    printf '%s' "api --method POST repos/${REPO}/pulls/42/comments -f commit_id=${REVIEW_HEAD_SHA} -f path=src/app.sh $1 -F body=@"
}

@test "pr review-comment reads the head once and posts one comment on a single line, on each side, with the right fields" {
    prepare_review_comment
    local side expected
    for side in "" RIGHT LEFT; do
        : > "${GH_LOG}"
        rm -f "${GH_FIXTURES}/review-comment-body.txt"
        run_review_comment --line 0012 --body-file "${TEST_TMP}/review.md" ${side:+--side "${side}"}
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [ "${output}" = "$(printf '%s\n' "inline${TAB}901" "url${TAB}${DISCUSSION_URL}#discussion_r901")" ]
        cmp "${TEST_TMP}/review.md" "${GH_FIXTURES}/review-comment-body.txt"
        [ "$(gh_call_count "api repos/${REPO}/pulls/42 --jq .head.sha")" -eq 1 ]
        expected="$(review_comment_post "-F line=12 -f side=${side:-RIGHT}")"
        [ "$(gh_call_count "${expected}")" -eq 1 ]
        [ "$(review_comment_posts)" -eq 1 ]
        [ "$(gh_call_count "start_")" -eq 0 ]
        [ "$(grep -c -- "--repo\|-f body=\|${TEST_TMP}/review.md\|never closes" "${GH_LOG}")" -eq 0 ]
        [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
        # The head is read before the post.
        [ "$(gh_line_of "api repos/${REPO}/pulls/42 ")" -lt "$(gh_line_of "api --method POST")" ]
    done
}

@test "pr review-comment posts a range with start_line and start_side on the side of --line, on each side" {
    prepare_review_comment
    local side expected
    for side in RIGHT LEFT; do
        : > "${GH_LOG}"
        run --separate-stderr "${SCRIPT}" pr review-comment --body-file "${TEST_TMP}/review.md" --side "${side}" --line 12 \
            --start-line 010 --path src/app.sh --pr 042 --repo "${REPO}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(printf '%s\n' "inline${TAB}901" "url${TAB}${DISCUSSION_URL}#discussion_r901")" ]
        cmp "${TEST_TMP}/review.md" "${GH_FIXTURES}/review-comment-body.txt"
        [ "$(gh_call_count "api repos/${REPO}/pulls/42 --jq .head.sha")" -eq 1 ]
        expected="$(review_comment_post "-F line=12 -f side=${side} -F start_line=10 -f start_side=${side}")"
        [ "$(gh_call_count "${expected}")" -eq 1 ]
        [ "$(review_comment_posts)" -eq 1 ]
    done
}

@test "pr review-comment reads the body from stdin and posts the copy it checked" {
    prepare_review_comment
    run_review_comment --line 12 --body-file - <<< "A comment from stdin"
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/review-comment-body.txt")" = "A comment from stdin" ]
    [ "$(review_comment_posts)" -eq 1 ]
}

@test "pr review-comment refuses a leaking body or --path with exit 8, naming the rule only, before reading or posting anything" {
    prepare_review_comment
    local token
    token="$(leak_tokens | head -1)"
    local -a leaks=("${token}" "see /home/someone/notes" $'a bell \x07 here' $'bad \xff byte')
    local -a rules=("token" "host path" "control character" "invalid UTF-8")
    local index
    for index in "${!leaks[@]}"; do
        write_leak_body "${leaks[index]}"
        run_review_comment --line 12 --body-file "${TEST_TMP}/leak.md"
        assert_refused "${status}" "${output}" "${stderr}" "${rules[index]}" "${leaks[index]}"
    done
    [ ! -f "${GH_LOG}" ]

    run --separate-stderr "${SCRIPT}" pr review-comment --repo "${REPO}" --pr 42 --path "docs/${token}.md" --line 12 --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: path refused: token" ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr review-comment refuses a plan-approval keyword outside a quote with exit 8, and posts one inside a quote" {
    prepare_review_comment
    local keyword
    while IFS= read -r keyword; do
        printf '%s\n' "${keyword}" > "${TEST_TMP}/review.md"
        run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: body refused: approval keyword (line 1)" ]
        [ ! -f "${GH_LOG}" ]
    done < <(sign_off_keywords)

    printf 'As the issue says:\n\n> %s\n' "$(sign_off_keywords | head -1)" > "${TEST_TMP}/review.md"
    run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/review.md" "${GH_FIXTURES}/review-comment-body.txt"
}

@test "pr review-comment refuses a blank, missing or unreadable body as a runtime failure, without calling gh" {
    prepare_review_comment
    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    run_review_comment --line 12 --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    run_review_comment --line 12 --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: cannot read the --body-file" ]
    [ -z "${output}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr review-comment exits 1 with a clear message when GitHub answers 422 for a line not in the diff, and never posts twice" {
    prepare_review_comment
    printf 'gh: Validation Failed (HTTP 422)\n' > "${GH_FIXTURES}/review-comment.fail"
    run_review_comment --line 12 --side LEFT --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the review comment was not posted: GitHub refused it (HTTP 422) because the --line, or a line of the range, is not part of the diff of ${REPO}#42 on the LEFT side, or the head moved after it was read; see 'cfwf pr diff'" ]
    [ "$(review_comment_posts)" -eq 1 ]

    local error
    for error in "gh: Not Found (HTTP 404)" "gh: Resource not accessible by integration (HTTP 403)"; do
        : > "${GH_LOG}"
        printf '%s\n' "${error}" > "${GH_FIXTURES}/review-comment.fail"
        run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
        [ "${status}" -eq 1 ]
        [ "${stderr}" = "cfwf: the review comment was not posted: ${error}" ]
        [ "$(review_comment_posts)" -eq 1 ]
    done

    local check="run 'cfwf pr comments' and look for it on the same path and line before posting again"
    for error in "gh: Bad Gateway (HTTP 502)" "gh: Too Many Requests (HTTP 429)"; do
        : > "${GH_LOG}"
        printf '%s\n' "${error}" > "${GH_FIXTURES}/review-comment.fail"
        run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
        [ "${status}" -eq 1 ]
        [ "${stderr}" = "cfwf: the review comment may have been posted (${error}); ${check}" ]
        [ "$(review_comment_posts)" -eq 1 ]
    done

    rm "${GH_FIXTURES}/review-comment.fail"
    local answer
    for answer in '{id: 901, html_url: "https://github.com/credfeto/credfeto-orchestrator/pull/43#discussion_r901"}' '{id: "x", html_url: "y"}' '{}'; do
        : > "${GH_LOG}"
        jq -n "${answer}" > "${GH_FIXTURES}/review-comment.json"
        run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the review comment may have been posted (gh returned an unexpected answer); ${check}" ]
        [ "$(review_comment_posts)" -eq 1 ]
    done
}

@test "pr review-comment exits 9 without posting for a pull request that does not exist, and 1 when the head cannot be read" {
    prepare_review_comment
    rm "$(api_fixture "repos/${REPO}/pulls/42").json"
    run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    [ "$(review_comment_posts)" -eq 0 ]

    fail_api "repos/${REPO}/pulls/42"
    run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#42: gh: Bad Gateway (HTTP 502)" ]
    rm "$(api_fixture "repos/${REPO}/pulls/42").fail"

    jq -n '{head: {sha: "not-a-sha"}}' | write_api "repos/${REPO}/pulls/42"
    run_review_comment --line 12 --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected head commit for ${REPO}#42" ]
    [ "$(review_comment_posts)" -eq 0 ]
}

@test "pr review-comment usage errors exit 2 with its usage on stderr and nothing on stdout, never echoing a value, before any gh call" {
    prepare_review_comment
    local body="--body-file ${TEST_TMP}/review.md" repo="--repo ${REPO}" args
    local -a cases=(
        "" "--pr 42 --path a --line 1 ${body}" "${repo} --path a --line 1 ${body}" "${repo} --pr 42 --line 1 ${body}"
        "${repo} --pr 42 --path a ${body}" "${repo} --pr 42 --path a --line 1"
        "${repo} --pr 0 --path a --line 1 ${body}" "${repo} --pr x --path a --line 1 ${body}" "${repo} --pr 42 --pr 42 --path a --line 1 ${body}"
        "--repo x --pr 42 --path a --line 1 ${body}" "${repo} ${repo} --pr 42 --path a --line 1 ${body}"
        "${repo} --pr 42 --path a --line 0 ${body}" "${repo} --pr 42 --path a --line -1 ${body}" "${repo} --pr 42 --path a --line x ${body}"
        "${repo} --pr 42 --path a --line 1234567890 ${body}" "${repo} --pr 42 --path a --line 1 --line 1 ${body}"
        "${repo} --pr 42 --path a --line 5 --start-line 5 ${body}" "${repo} --pr 42 --path a --line 5 --start-line 6 ${body}"
        "${repo} --pr 42 --path a --line 5 --start-line 0 ${body}" "${repo} --pr 42 --path a --line 5 --start-line 1 --start-line 2 ${body}"
        "${repo} --pr 42 --path a --line 1 --side right ${body}" "${repo} --pr 42 --path a --line 1 --side BOTH ${body}"
        "${repo} --pr 42 --path a --line 1 --side LEFT --side LEFT ${body}"
        "${repo} --pr 42 --path /a --line 1 ${body}" "${repo} --pr 42 --path a/../b --line 1 ${body}" "${repo} --pr 42 --path .. --line 1 ${body}"
        "${repo} --pr 42 --path ./a --line 1 ${body}" "${repo} --pr 42 --path a//b --line 1 ${body}" "${repo} --pr 42 --path a/ --line 1 ${body}"
        "${repo} --pr 42 --path a --path b --line 1 ${body}" "${repo} --pr 42 --path a --line 1 ${body} ${body}"
        "${repo} --pr 42 --path a --line 1 --body x" "${repo} --pr 42 --path a --line 1 --commit-id ${REVIEW_HEAD_SHA} ${body}"
        "${repo} --pr 42 --path a --line 1 ${body} extra" "${repo} --pr 42 --path a --line"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr review-comment ${args}
        if [ "${status}" -ne 2 ]; then
            echo "accepted: ${args} (${status})" >&2
            return 1
        fi
        [ -z "${output}" ]
        if [[ "${stderr}" != "cfwf: "*$'\n\n'"${REVIEW_COMMENT_USAGE}"$'\n'* ]]; then
            echo "usage: ${args}" >&2
            return 1
        fi
    done

    local path
    for path in $'a\tb' $'a\x01b' $'a\nb'; do
        run_review_comment --line 1 --body-file "${TEST_TMP}/review.md" --path "${path}"
        [ "${status}" -eq 2 ]
    done
    run --separate-stderr "${SCRIPT}" pr review-comment --repo "${REPO}" --pr 42 --path $'a\x7fb' --line 1 --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --path: it must not contain a control character"$'\n'* ]]
    run --separate-stderr "${SCRIPT}" pr review-comment --repo "${REPO}" --pr 42 --path a --line 5 --start-line 7 --body-file "${TEST_TMP}/review.md"
    [[ "${stderr}" == "cfwf: invalid value for --start-line: it must be below --line"$'\n'* ]]

    local secret
    secret="$(leak_tokens | head -1)"
    run --separate-stderr "${SCRIPT}" pr review-comment --repo "${REPO}" --pr 42 --path "a/../${secret}" --line 1 --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"${secret}"* ]]
    run --separate-stderr "${SCRIPT}" pr review-comment --repo "${REPO}" --pr 42 --path a --line "${secret}" --body-file "${TEST_TMP}/review.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"${secret}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr review-comment help, from -h, --help and help, gives the usage, the rules, the output, the retry rule and every exit code; help pr and the general help point to it; none calls gh" {
    local invocation
    for invocation in "pr review-comment -h" "pr review-comment --help" "help pr review-comment"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [[ "${output}" == "${REVIEW_COMMENT_USAGE}"$'\n'* ]]
        [[ "${output}" == *"never passed to gh api."* ]]
        [[ "${output}" == *"There is no --body."* ]]
        [[ "${output}" == *"There is no --commit-id: the comment is put on the"$'\n'"pull request's head, read once when the command runs."* ]]
        [[ "${output}" == *"RIGHT (the default)"* ]]
        [[ "${output}" == *"\"cfwf: path refused: <rule>\""* ]]
        [[ "${output}" == *$'\n'"  inline  the new comment's id, the id 'cfwf pr reply --comment-id' takes"$'\n'"  url     the new comment's URL"$'\n'* ]]
        [[ "${output}" == *"It posts once and never tries again. When GitHub answers HTTP 422, the comment was not posted:"* ]]
        [[ "${output}" == *"do not run it again blindly. Run 'cfwf pr comments'"* ]]
        [[ "${output}" == *"Exit codes: 0 posted; 8 the body or --path was refused; 9 the pull request was not found"* ]]
        [[ "${output}" == *"prefixed \"cfwf:\"; 2 a usage error."* ]]
        [[ "${output}" != *"usage_"* ]]
    done
    run "${SCRIPT}" help pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"Run 'cfwf pr reply --help' for pr reply, which replies to an inline review comment."$'\n'"Run 'cfwf pr review-comment --help' for pr review-comment, which posts a new inline review comment"$'\n'"on a line or a range of lines of a pull request's diff."$'\n'"Run 'cfwf pr ready-at --help'"* ]]
    run "${SCRIPT}" help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"  pr reply "*$'\n'"  pr review-comment        Post a new inline review comment on a line or a range of a PR's diff (exit 8 refused, 9 not found)"$'\n'"  pr hand-off "* ]]
    [ ! -f "${GH_LOG}" ]
}
