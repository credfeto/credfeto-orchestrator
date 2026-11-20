#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- issue view and issue plan-status -------------------------------------------

# The plan-at and plan-by lines plan-status prints when the plan is the issue_comment whose number
# is $1, login $2 and association $3.
plan_lines() {
    printf 'plan-at\t%s\nplan-by\t%s\t%s\t%s' "$(comment_time "$1")" "$2" "$3" "$(comment_url "$1")"
}

# The two lines every plan-status answer starts with: whether there is a plan ($1) and whether the
# issue is Blocked ($2), each yes or no.
plan_status_head() {
    printf 'plan\t%s\nblocked\t%s' "$1" "$2"
}

# The comment line plan-status prints for the issue_comment whose number is $1, login $2,
# association $3 and sign-off answer $4.
comment_line() {
    printf 'comment\t%s\t%s\t%s\t%s\t%s' "$(comment_time "$1")" "$2" "$3" "$4" "$(comment_url "$1")"
}

# Prints yes or no for each body given, one per line and in order: what plan-status says of a
# comment with that body posted after the plan. Every body is a comment of one thread, read in one run.
sign_off_answers() {
    local body number=1
    local -a comments=()
    write_issue 7 "A title" OPEN "The request."
    comments+=("$(issue_comment 1 credfeto OWNER "${PLAN_HEADING}")")
    for body; do
        number=$((number + 1))
        comments+=("$(issue_comment "${number}" someone MEMBER "${body}")")
    done
    write_comments 7 "${comments[@]}"
    "${SCRIPT}" issue plan-status --repo "${REPO}" --issue 7 < /dev/null | awk -F '\t' '$1 == "comment" { print $5 }'
}

# plan-status answers $1 (yes or no) for every one of the comment bodies that follow; the first
# body with another answer is named.
assert_sign_off() {
    local expected="$1" body index=0
    local -a answers=()
    shift
    mapfile -t answers < <(sign_off_answers "$@")
    [ "${#answers[@]}" -eq "$#" ] || { echo "expected $# answers, got ${#answers[@]}" >&2; return 1; }
    for body; do
        [ "${answers[index]}" = "${expected}" ] || { echo "not ${expected}: ${body}" >&2; return 1; }
        index=$((index + 1))
    done
}

@test "issue view and issue plan-status help, from each -h and from help issue, describes the exit codes and calls no gh" {
    local invocation
    for invocation in "issue view -h" "issue view --help" "issue view --repo ${REPO} --help" "help issue" "issue -h"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf issue view ${ISSUE_READ_USAGE}"* ]]
        [[ "${output}" == *"Exit codes: 0 printed; 9 the issue does not exist"*"1 a runtime failure"*"2 a usage error."* ]]
        [[ "${output}" == *"exactly as GitHub returns it"* ]]
    done
    for invocation in "issue plan-status -h" "issue plan-status --help" "help issue" "issue --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf issue plan-status ${ISSUE_READ_USAGE}"* ]]
        [[ "${output}" == *"It never prints a comment body."* ]]
        [[ "${output}" == *"A yes is not an approval"* ]]
    done

    # The help of one subcommand is that subcommand's alone.
    run "${SCRIPT}" issue view -h
    [[ "${output}" != *"cfwf issue create"* && "${output}" != *"cfwf issue plan-status"* ]]
    run "${SCRIPT}" issue plan-status -h
    [[ "${output}" != *"cfwf issue create"* && "${output}" != *"cfwf issue view"* ]]
    run "${SCRIPT}" issue create -h
    [[ "${output}" != *"cfwf issue view"* && "${output}" != *"cfwf issue plan-status"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "help for a command and its subcommand prints what that subcommand's -h prints, and the command's usage for a subcommand it does not know" {
    local pair spelling expected
    for pair in "issue create" "issue view" "issue plan-status" "issue list" "issue search" "issue label-history" "issue add-sub-issue" "issue post-plan" "issue block" "body check" "pr checks" "pr ready-at" "pr auto-merge-at" "pr diff" "pr block" "pr post-merge-runs" "pr sync-labels" "pr review-comment" "comment add" "comment edit" "label create" "release view" "release list" "tag view"; do
        # shellcheck disable=SC2086  # each pair is split into its two words on purpose
        run "${SCRIPT}" ${pair} -h
        [ "${status}" -eq 0 ]
        expected="${output}"
        [[ "${expected}" == "Usage: cfwf ${pair} "* ]]
        for spelling in help -h --help; do
            # shellcheck disable=SC2086  # each pair is split into its two words on purpose
            run "${SCRIPT}" "${spelling}" ${pair}
            [ "${status}" -eq 0 ]
            [ "${output}" = "${expected}" ] || { echo "${spelling} ${pair} differs from ${pair} -h" >&2; return 1; }
        done
    done

    # A subcommand the command does not have, or a word after a command that has none, is not an
    # error for help: it prints the usage of the command, and the general usage for no command.
    run "${SCRIPT}" help issue
    expected="${output}"
    [[ "${expected}" == *"Usage: cfwf issue view ${ISSUE_READ_USAGE}"* ]]
    run "${SCRIPT}" help issue frobnicate
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
    run "${SCRIPT}" help closing-issue-labels frobnicate
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf closing-issue-labels "* ]]
    run "${SCRIPT}" help
    expected="${output}"
    run "${SCRIPT}" help frobnicate view
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue view and issue plan-status usage errors exit 2 with their own usage, before any gh call" {
    local -a cases=(
        "--repo ${REPO}"
        "--issue 7"
        ""
        "--repo ${REPO} --issue 7 --repo ${REPO}"
        "--repo ${REPO} --issue 7 --issue 7"
        "--repo ${REPO} --issue x7"
        "--repo ${REPO} --issue 7x"
        "--repo ${REPO} --issue -7"
        "--repo ${REPO} --issue 7;8"
        "--repo ${REPO} --issue #7"
        "--repo not-a-repo --issue 7"
        "--repo ../.. --issue 7"
        "--repo ${REPO} --issue 7 --json title"
        "--repo ${REPO} --issue 7 --jq ."
        "--repo ${REPO} --issue 7 --template x"
        "--repo ${REPO} --issue 7 --web"
        "--repo ${REPO} --issue 7 --pr 7"
        "--repo ${REPO} --issue 7 --title T"
        "--repo ${REPO} --issue 7 extra"
        "--repo ${REPO} --issue"
    )
    local subcommand args
    local -a own_cases
    for subcommand in view plan-status; do
        own_cases=("${cases[@]}")
        if [ "${subcommand}" = view ]; then
            own_cases+=("--repo ${REPO} --issue 7 --comments --comments" "--repo ${REPO} --issue 7 --comments yes")
        else
            own_cases+=("--repo ${REPO} --issue 7 --comments")
        fi
        for args in "${own_cases[@]}"; do
            # shellcheck disable=SC2086  # each case is split into its words on purpose
            run --separate-stderr "${SCRIPT}" issue "${subcommand}" ${args}
            [ "${status}" -eq 2 ] || { echo "accepted: ${subcommand} ${args} (${status})" >&2; return 1; }
            [ -z "${output}" ]
            [[ "${stderr}" == *"Usage: cfwf issue ${subcommand} ${ISSUE_READ_USAGE}"* ]]
            [[ "${stderr}" != *"cfwf issue create"* ]]
        done

        run_issue_read "${subcommand}" --issue ""
        [ "${status}" -eq 2 ]
        [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --issue: it must be a number" ]]

        run --separate-stderr "${SCRIPT}" issue "${subcommand}" --issue 7
        [[ "${stderr%%$'\n'*}" == "cfwf: missing required option --repo" ]]
        run_issue_read "${subcommand}"
        [[ "${stderr%%$'\n'*}" == "cfwf: missing required option --issue" ]]
        run_issue_read "${subcommand}" --issue 7 --repo "${REPO}"
        [[ "${stderr%%$'\n'*}" == "cfwf: --repo can only be given once" ]]
        run_issue_read "${subcommand}" --issue 7 --issue 8
        [[ "${stderr%%$'\n'*}" == "cfwf: --issue can only be given once" ]]
        run_issue_read "${subcommand}" --issue x7
        [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --issue: it must be a number" ]]
        run_issue_read "${subcommand}" --issue 7 --json title
        [[ "${stderr%%$'\n'*}" == "cfwf: unknown option (argument 7; its value is not shown)" ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue view prints an open issue's title, state, labels and assignees, then its body unchanged, in one gh call" {
    local body=$'First line\twith a tab.\n\n\n  indented, with trailing spaces   \nand a trailing tab\t\n\nlast line\n\n'
    write_issue 7 "A title: with 'quotes', a \\ and a | pipe" OPEN "${body}" AI-Work Medium "two words" -- credfeto someone-else
    "${SCRIPT}" issue view --repo "${REPO}" --issue 7 > "${TEST_TMP}/out" 2> "${TEST_TMP}/err" < /dev/null
    printf 'title\t%s\nstate\tOPEN\nlabels\tAI-Work,Medium,two words\nassignees\tcredfeto,someone-else\n\n%s\n' \
        "A title: with 'quotes', a \\ and a | pipe" "${body}" > "${TEST_TMP}/expected"
    cmp "${TEST_TMP}/expected" "${TEST_TMP}/out"
    [ ! -s "${TEST_TMP}/err" ]
    assert_one_issue_read 7 "${VIEW_FIELDS}"
}

@test "issue view prints a closed issue with no labels, no assignees and no body, each field still on its line" {
    write_issue 7 "Done" CLOSED ""
    "${SCRIPT}" issue view --repo "${REPO}" --issue 7 > "${TEST_TMP}/out" < /dev/null
    printf 'title\tDone\nstate\tCLOSED\nlabels\t\nassignees\t\n\n\n' > "${TEST_TMP}/expected"
    cmp "${TEST_TMP}/expected" "${TEST_TMP}/out"

    # GitHub can answer a body that was never set with null.
    jq '.body = null' "$(issue_fixture 7).json" > "${TEST_TMP}/null-body.json"
    mv "${TEST_TMP}/null-body.json" "$(issue_fixture 7).json"
    "${SCRIPT}" issue view --repo "${REPO}" --issue 7 > "${TEST_TMP}/out" < /dev/null
    cmp "${TEST_TMP}/expected" "${TEST_TMP}/out"
}

@test "issue view keeps a body that is only whitespace, or that ends without a newline, byte for byte" {
    local body
    for body in $'\n\n' $' \t ' "no newline at the end" $'ends with spaces  \n\n\n\n' $'CRLF line\r\nand another\r\n'; do
        write_issue 7 "T" OPEN "${body}"
        "${SCRIPT}" issue view --repo "${REPO}" --issue 7 > "${TEST_TMP}/out" < /dev/null
        printf 'title\tT\nstate\tOPEN\nlabels\t\nassignees\t\n\n%s\n' "${body}" > "${TEST_TMP}/expected"
        cmp "${TEST_TMP}/expected" "${TEST_TMP}/out"
    done
}

@test "issue view prints each control character in a title or a label as a space, so every field stays on its line" {
    # A tab, a newline, ESC, U+009B (CSI, in C1) and DEL are controls; U+00A0, just past C1, is not.
    write_issue 7 $'a\tb\nc\x1b[1md\xc2\x9be\x7ff\xc2\xa0g' OPEN "The body." $'odd\tlabel' $'two\nlines'
    run_issue_read view --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "title"$'\t'"a b c [1md e f"$'\xc2\xa0'"g"$'\n'"state"$'\t'"OPEN"$'\n'"labels"$'\t'"odd label,two lines"$'\n'"assignees"$'\t'$'\n\n'"The body." ]
    [ -z "${stderr}" ]
}

@test "issue view and issue plan-status exit 9 for a number that is no issue, or that is a pull request's" {
    local subcommand
    # gh issue view answers a pull request's number with the pull request.
    write_issue 8 "A pull request" MERGED "Its description."
    jq --arg url "https://github.com/${REPO}/pull/8" '.url = $url' "$(issue_fixture 8).json" > "${TEST_TMP}/pull.json"
    mv "${TEST_TMP}/pull.json" "$(issue_fixture 8).json"
    for subcommand in view plan-status; do
        run_issue_read "${subcommand}" --issue 404
        [ "${status}" -eq 9 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: ${REPO}#404 was not found" ]

        run_issue_read "${subcommand}" --issue 8
        [ "${status}" -eq 9 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: ${REPO}#8 is a pull request, not an issue" ]
    done
}

@test "issue view and issue plan-status read a number given with leading zeros as that number, without them" {
    local subcommand fields
    write_issue 7 "A title" OPEN "The request."
    for subcommand in view plan-status; do
        fields="${VIEW_FIELDS}"
        [ "${subcommand}" = view ] || fields="${PLAN_STATUS_FIELDS}"
        rm -f "${GH_LOG}"
        run_issue_read "${subcommand}" --issue 007
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        assert_one_issue_read 7 "${fields}"

        # A message names the number the same way.
        run_issue_read "${subcommand}" --issue 00404
        [ "${status}" -eq 9 ]
        [ "${stderr}" = "cfwf: ${REPO}#404 was not found" ]
    done
}

@test "issue view and issue plan-status report a failing gh as a runtime failure (exit 1), never as a missing issue" {
    local subcommand
    write_issue 7 "A title" OPEN "The request."
    for subcommand in view plan-status; do
        printf 'gh: Bad Gateway (HTTP 502)\n' > "$(issue_fixture 7).fail"
        run_issue_read "${subcommand}" --issue 7
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: could not read ${REPO}#7: gh: Bad Gateway (HTTP 502)" ]

        # A repository GitHub does not show the caller is not a missing issue either.
        printf "GraphQL: Could not resolve to a Repository with the name '%s'. (repository)\n" "${REPO}" > "$(issue_fixture 7).fail"
        run_issue_read "${subcommand}" --issue 7
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: could not read ${REPO}#7: GraphQL: Could not resolve to a Repository"* ]]
    done
}

@test "issue view refuses a state it does not know as a runtime failure, printing nothing" {
    write_issue 7 "A title" LOCKED "The request."
    run_issue_read view --issue 7
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#7" ]
}

@test "issue view and issue plan-status leave no temporary file behind, whether the read works or fails" {
    local subcommand scratch="${TEST_TMP}/scratch"
    mkdir -p "${scratch}"
    write_issue 7 "A title" OPEN "The request."
    for subcommand in view plan-status; do
        TMPDIR="${scratch}" run_issue_read "${subcommand}" --issue 7
        [ "${status}" -eq 0 ]
        [ -z "$(ls -A "${scratch}")" ]
        TMPDIR="${scratch}" run_issue_read "${subcommand}" --issue 404
        [ "${status}" -eq 9 ]
        [ -z "$(ls -A "${scratch}")" ]
    done
}

@test "issue plan-status reports no plan, and no comment lines, for an issue with no plan comment, in one gh call" {
    local keyword
    keyword="$(sign_off_keywords | head -1)"
    write_issue 7 "A title" OPEN "${PLAN_HEADING} in the description is not a plan comment."
    run_issue_read plan-status --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head no no)" ]
    [ -z "${stderr}" ]
    assert_one_issue_read 7 "${PLAN_STATUS_FIELDS}"

    # Only a line that is the heading and nothing else makes a comment a plan: not one in another
    # case, with anything before or after the heading on its line, or of another heading level.
    write_comments 7 "$(issue_comment 1 someone MEMBER "${PLAN_HEADING,,}")" \
        "$(issue_comment 2 someone MEMBER "${PLAN_HEADING^^}")" \
        "$(issue_comment 3 someone MEMBER " ${PLAN_HEADING}")" \
        "$(issue_comment 4 someone MEMBER "${PLAN_HEADING} (revised)")" \
        "$(issue_comment 5 someone MEMBER "${PLAN_HEADING}ning notes")" \
        "$(issue_comment 6 someone MEMBER "${PLAN_HEADING} ")" \
        "$(issue_comment 7 someone MEMBER "See the ${PLAN_HEADING}")" \
        "$(issue_comment 8 someone MEMBER "### Implementation Plan")" \
        "$(issue_comment 9 credfeto OWNER "${keyword}")"
    run_issue_read plan-status --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head no no)" ]
}

@test "issue plan-status takes a comment as a plan wherever its heading line is, with LF or CRLF line endings" {
    local body
    write_issue 7 "A title" OPEN "The request."
    for body in "${PLAN_HEADING}" "${PLAN_HEADING}"$'\n\n'"Step one." "See the plan below."$'\n\n'"${PLAN_HEADING}"$'\n'"Step one." \
        "A preamble."$'\r\n\r\n'"${PLAN_HEADING}"$'\r\n'"Step one."$'\r\n' "${PLAN_HEADING}"$'\r'; do
        write_comments 7 "$(issue_comment 1 planner-bot NONE "${body}")"
        run_issue_read plan-status --issue 7
        [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 1 planner-bot NONE)" ] || { echo "not a plan: ${body}" >&2; return 1; }
    done
}

@test "issue plan-status reports the plan's time and each later comment in order, leaving out the comments before the plan" {
    write_issue 7 "A title" OPEN "The request."
    write_comments 7 "$(issue_comment 1 early-bird CONTRIBUTOR "A question before the plan.")" \
        "$(issue_comment 2 planner-bot NONE "${PLAN_HEADING}"$'\n\n'"Step one.")" \
        "$(issue_comment 3 credfeto OWNER "A question after the plan.")" \
        "$(issue_comment 4 someone MEMBER "Another remark.")"
    run_issue_read plan-status --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 2 planner-bot NONE)"$'\n'"$(comment_line 3 credfeto OWNER no)"$'\n'"$(comment_line 4 someone MEMBER no)" ]
    [ -z "${stderr}" ]
    assert_one_issue_read 7 "${PLAN_STATUS_FIELDS}"

    # A plan nobody has answered yet has no comment lines.
    write_comments 7 "$(issue_comment 1 early-bird CONTRIBUTOR "A question before the plan.")" \
        "$(issue_comment 2 planner-bot NONE "${PLAN_HEADING}")"
    run_issue_read plan-status --issue 7
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 2 planner-bot NONE)" ]
}

@test "issue plan-status takes the latest of two plans, and only the comments after it" {
    local keyword
    keyword="$(sign_off_keywords | head -1)"
    write_issue 7 "A title" OPEN "The request."
    write_comments 7 "$(issue_comment 1 planner-bot NONE "${PLAN_HEADING}"$'\n'"The first plan.")" \
        "$(issue_comment 2 credfeto OWNER "${keyword}")" \
        "$(issue_comment 3 planner-bot NONE "The plan, revised."$'\n\n'"${PLAN_HEADING}"$'\n'"The second plan.")" \
        "$(issue_comment 4 credfeto OWNER "Still reading.")"
    run_issue_read plan-status --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 3 planner-bot NONE)"$'\n'"$(comment_line 4 credfeto OWNER no)" ]

    # A later comment whose heading is in another case is not a plan, so it does not become the latest.
    write_comments 7 "$(issue_comment 1 planner-bot NONE "${PLAN_HEADING}")" \
        "$(issue_comment 2 someone NONE "${PLAN_HEADING^^}")"
    run_issue_read plan-status --issue 7
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 1 planner-bot NONE)"$'\n'"$(comment_line 2 someone NONE no)" ]
}

@test "issue plan-status reports who wrote the latest plan, so a caller can tell a plan from an author it does not trust" {
    local keyword
    keyword="$(sign_off_keywords | head -1)"
    write_issue 7 "A title" OPEN "The request."
    write_comments 7 "$(issue_comment 1 planner-bot NONE "${PLAN_HEADING}"$'\n'"The real plan.")" \
        "$(issue_comment 2 stranger NONE "${PLAN_HEADING}"$'\n'"Another plan altogether.")" \
        "$(issue_comment 3 credfeto OWNER "${keyword}")"
    run_issue_read plan-status --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 2 stranger NONE)"$'\n'"$(comment_line 3 credfeto OWNER yes)" ]

    # A plan from a deleted account has an empty login, and keeps its four fields.
    write_comments 7 "$(issue_comment 1 "" NONE "${PLAN_HEADING}")"
    run_issue_read plan-status --issue 7
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 1 "" NONE)" ]
}

@test "issue plan-status reports blocked for a label named Blocked in any case, and for no other label" {
    local label
    for label in Blocked blocked BLOCKED; do
        write_issue 7 "A title" OPEN "The request." AI-Work "${label}" Medium
        run_issue_read plan-status --issue 7
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(plan_status_head no yes)" ] || { echo "${label}: ${output}" >&2; return 1; }
    done
    for label in Blocked-by-upstream Unblocked "Not Blocked" On-Hold; do
        write_issue 7 "A title" OPEN "The request." AI-Work "${label}"
        run_issue_read plan-status --issue 7
        [ "${output}" = "$(plan_status_head no no)" ] || { echo "${label}: ${output}" >&2; return 1; }
    done
    write_issue 7 "A title" OPEN "The request."
    run_issue_read plan-status --issue 7
    [ "${output}" = "$(plan_status_head no no)" ]
}

@test "issue plan-status says yes for a line that is only a sign-off keyword, in any case, with whitespace around it" {
    local keyword
    while IFS= read -r keyword; do
        assert_sign_off yes "${keyword}" "${keyword^^}" "${keyword^}" "  ${keyword^}  " $'\t'"${keyword}"$'\t' \
            "A first line."$'\n\n'"${keyword}" "A first line."$'\r\n'"${keyword}"$'\r\n' "${keyword}"$'\n'"A last line." \
            "Not this one."$'\n'"  ${keyword^^}"$'\n'"Nor this one."
    done < <(sign_off_keywords)
}

@test "issue plan-status says no for a sign-off keyword with anything else on its line, and for a comment with none" {
    local keyword zero_width_space=$'\xe2\x80\x8b'
    while IFS= read -r keyword; do
        assert_sign_off no "${keyword^^}!" "not ${keyword}" "${keyword^^} but fix X" "${keyword:0:2}${zero_width_space}${keyword:2}" \
            "${zero_width_space}${keyword}" "${keyword}." "Thanks, ${keyword}!" "(${keyword})" "Is this ${keyword}?" \
            "_${keyword}_" "__${keyword^^}__" "**${keyword}**" "\`${keyword}\`" \
            "plan_${keyword}" "${keyword}_by" "un${keyword}" "${keyword}s" "${keyword}2" "x_${keyword}_y" "_${keyword}_x" \
            "A comment with no keyword." ""
    done < <(sign_off_keywords)
}

@test "comment add refuses exactly the lines issue plan-status reads as a sign-off, and posts a sentence that only mentions a keyword" {
    local keyword line
    prepare_comment
    while IFS= read -r keyword; do
        for line in "${keyword}" "${keyword^^}" "  ${keyword^}  " $'\t'"${keyword}"; do
            assert_sign_off yes "${line}"
            write_leak_body "${line}"
            run_comment_add --pr 1623 --body-file "${TEST_TMP}/leak.md"
            assert_refused "${status}" "${output}" "${stderr}" "approval keyword" "${line}"
        done
        for line in "${keyword^^}!" "not ${keyword}" "${keyword^^} but fix X" "Write ${keyword} on a line of its own to sign off." "> ${keyword}"; do
            assert_sign_off no "${line}"
            write_leak_body "${line}"
            run_comment_add --pr 1623 --body-file "${TEST_TMP}/leak.md"
            [ "${status}" -eq 0 ]
            cmp "${TEST_TMP}/leak.md" "${GH_FIXTURES}/comment-body.txt"
        done
    done < <(sign_off_keywords)
}

@test "issue plan-status ignores a sign-off keyword on a Markdown quote line" {
    local keyword
    while IFS= read -r keyword; do
        assert_sign_off no "> ${keyword}" ">${keyword}" " > ${keyword}" "   > ${keyword}" "> > ${keyword}" \
            "> ${keyword}"$'\n\n'"Quoting the reviewer above." "As they said:"$'\r\n'"> ${keyword}"$'\r\n'
        # A keyword alone on a line after a quote counts. Four spaces or a tab before > make code, not
        # a quote, but the > is still on the line, so the keyword is not alone there.
        assert_sign_off yes "> quoted"$'\n'"${keyword}" "> ${keyword}"$'\n\n'"${keyword}"
        assert_sign_off no "    > ${keyword}" $'\t'"> ${keyword}" "a > ${keyword}"
    done < <(sign_off_keywords)
}

@test "issue plan-status never prints a comment body, and keeps every line in its fields whatever a comment holds" {
    local keyword
    keyword="$(sign_off_keywords | tail -1)"
    write_issue 7 "A title" OPEN "The request body."
    write_comments 7 "$(issue_comment 1 planner-bot NONE "${PLAN_HEADING}"$'\n'"plan-text-marker")" \
        "$(issue_comment 2 credfeto OWNER "${keyword}"$'\n'"comment"$'\t'"forged"$'\t'"line-marker")" \
        "$(issue_comment 3 "" NONE "from a deleted account")"
    run_issue_read plan-status --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 1 planner-bot NONE)"$'\n'"$(comment_line 2 credfeto OWNER yes)"$'\n'"$(comment_line 3 "" NONE no)" ]
    [[ "${output}" != *marker* && "${output}" != *"request body"* && "${output}" != *"deleted account"* ]]
    [ -z "${stderr}" ]
}

# --- issue plan-status --approval (#1772) ----------------------------------------

# The account the agent works as, which the stub answers gh api user with.
APPROVAL_AGENT="the-agent"

# Writes what --approval reads beyond the issue: the agent's login, and the collaborators of REPO:
# someone and planner (people), and the agent and the PR creator (accounts that must never approve).
prepare_approval() {
    jq -n --arg login "${APPROVAL_AGENT}" '{login: $login, id: 2}' | write_api user
    write_collaborators "$(collaborator someone write)" "$(collaborator planner write)" \
        "$(collaborator "${APPROVAL_AGENT}" write)" "$(collaborator prpixie write)"
}

# The approved verdict plan-status --approval prints for issue 7, already written: yes or no.
approval_verdict() {
    "${SCRIPT}" issue plan-status --repo "${REPO}" --issue 7 --approval < /dev/null | awk -F '\t' '$1 == "approved" { print $2 }'
}

# Writes issue 7 with a plan by planner (COLLABORATOR) and then one comment with body $1 by login $2
# (default someone) with association $3 (default COLLABORATOR), and prints the verdict.
approval_of() {
    write_issue 7 "A title" OPEN "The request."
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}"$'\n'"The plan.")" \
        "$(issue_comment 2 "${2-someone}" "${3:-COLLABORATOR}" "$1")"
    approval_verdict
}

# Every body after $1 (yes or no) gets that verdict from someone, a COLLABORATOR; the first that
# does not is named.
assert_approval() {
    local expected="$1" body verdict
    shift
    for body; do
        verdict="$(approval_of "${body}")"
        [ "${verdict}" = "${expected}" ] || { echo "expected ${expected}, got '${verdict}': ${body}" >&2; return 1; }
    done
}

@test "issue plan-status --approval is described in its help, takes no value, and is refused on issue view" {
    run "${SCRIPT}" issue plan-status -h
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf issue plan-status --repo <owner/repo> --issue <n> [--approval]"$'\n'* ]]
    [[ "${output}" == *"no keyword, login or author"* ]]
    [[ "${output}" == *"approved     <yes|no>"* ]]
    [ ! -s "${GH_LOG}" ]
    run_issue_read plan-status --issue 7 --approval=yes
    [ "${status}" -eq 2 ]
    run_issue_read view --issue 7 --approval
    [ "${status}" -eq 2 ]
    [ ! -s "${GH_LOG}" ]
}

@test "issue plan-status --approval says yes for a collaborator's sign-off keyword as a whole word on a line of its own making, and prints who and when" {
    local keyword
    prepare_approval
    while IFS= read -r keyword; do
        assert_approval yes "${keyword}" "${keyword^^}" "${keyword^}." "Thanks, ${keyword}!" "(${keyword})" "**${keyword}**" \
            "\`${keyword}\`" "A first line."$'\n\n'"${keyword}" "Read it."$'\r\n'"${keyword}, ship it"$'\r\n' \
            "${keyword}"$'\n'"No objections from me." "> quoting the plan"$'\n'"${keyword}"
    done < <(sign_off_keywords)
    keyword="$(sign_off_keywords | head -1)"
    approval_of "${keyword}" > /dev/null
    run_issue_read plan-status --issue 7 --approval
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 1 planner COLLABORATOR)"$'\n'"$(comment_line 2 someone COLLABORATOR yes)"$'\n'"approved"$'\t'"yes"$'\n'"approved-by"$'\t'"someone"$'\t'"COLLABORATOR"$'\t'"$(comment_url 2)"$'\n'"approved-at"$'\t'"$(comment_time 2)" ]
    [ -z "${stderr}" ]
}

@test "issue plan-status --approval says no for the phrases only the old prompt check took, and for emphasis only plan-status's signal took" {
    local keyword
    prepare_approval
    assert_approval no "go ahead" "Go ahead." "looks good" "Looks good to me" "ship it" "+1" "yes" "ok"
    while IFS= read -r keyword; do
        assert_approval no "_${keyword}_" "__${keyword^^}__" "so _${keyword}_." "plan_${keyword}" "${keyword}_by" "un${keyword}" \
            "dis${keyword}" "${keyword}s" "${keyword}2" "> ${keyword}" "   > ${keyword}" "> > ${keyword}" ""
    done < <(sign_off_keywords)
}

@test "issue plan-status --approval says no for a keyword on a line with a negation, a condition or a question" {
    local keyword
    prepare_approval
    while IFS= read -r keyword; do
        assert_approval no "not ${keyword} yet" "Not ${keyword}." "${keyword}? not sure" "Is this ${keyword}?" \
            "${keyword} if you fix the tests" "${keyword} once CI passes" "${keyword} unless someone objects" \
            "I don't think it is ${keyword}" "I dont say ${keyword}" "can't say ${keyword}" "won't be ${keyword}" \
            "isn't ${keyword}" "never ${keyword}" "${keyword} - pending review" "nearly ${keyword}" "almost ${keyword}" \
            "partially ${keyword}" "awaiting ${keyword}" "${keyword} until Friday" "No, ${keyword} is wrong" \
            "${keyword}. No objections." "cannot be ${keyword}"
    done < <(sign_off_keywords)
}

@test "issue plan-status --approval counts only a collaborator or the owner, never a bot, the agent, the PR creator or the plan's own author" {
    local keyword
    prepare_approval
    keyword="$(sign_off_keywords | tail -1)"
    [ "$(approval_of "${keyword}" credfeto OWNER)" = yes ]
    [ "$(approval_of "${keyword}" someone MEMBER)" = yes ]
    [ "$(approval_of "${keyword}" stranger NONE)" = no ]
    [ "$(approval_of "${keyword}" stranger CONTRIBUTOR)" = no ]
    # An association GitHub gives that the collaborator list does not back up, and the reverse.
    [ "$(approval_of "${keyword}" stranger COLLABORATOR)" = no ]
    [ "$(approval_of "${keyword}" someone CONTRIBUTOR)" = no ]
    [ "$(approval_of "${keyword}" someone NONE)" = no ]
    [ "$(approval_of "${keyword}" "github-actions[bot]" COLLABORATOR)" = no ]
    [ "$(approval_of "${keyword}" "copilot-pull-request-reviewer[bot]" MEMBER)" = no ]
    [ "$(approval_of "${keyword}" "${APPROVAL_AGENT}" COLLABORATOR)" = no ]
    [ "$(approval_of "${keyword}" "${APPROVAL_AGENT^^}" COLLABORATOR)" = no ]
    [ "$(approval_of "${keyword}" prpixie COLLABORATOR)" = no ]
    [ "$(approval_of "${keyword}" planner COLLABORATOR)" = no ]
    [ "$(approval_of "${keyword}" "" NONE)" = no ]
    # A later approver who is allowed still approves after one who is not.
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}")" \
        "$(issue_comment 2 "${APPROVAL_AGENT}" COLLABORATOR "${keyword}")" \
        "$(issue_comment 3 someone COLLABORATOR "${keyword}")"
    run_issue_read plan-status --issue 7 --approval
    [[ "${output}" == *$'\n'"approved-by"$'\t'"someone"$'\t'"COLLABORATOR"$'\t'"$(comment_url 3)"$'\n'* ]]
}

@test "issue plan-status --approval needs the approval after the latest plan, counting any comment with the heading in any case as a plan" {
    local keyword
    prepare_approval
    keyword="$(sign_off_keywords | head -1)"
    write_issue 7 "A title" OPEN "The request."
    write_comments 7 "$(issue_comment 1 someone COLLABORATOR "${keyword}")" \
        "$(issue_comment 2 planner COLLABORATOR "${PLAN_HEADING}")"
    [ "$(approval_verdict)" = no ]
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}")" \
        "$(issue_comment 2 someone COLLABORATOR "${keyword}")" \
        "$(issue_comment 3 planner COLLABORATOR "Revised."$'\n\n'"${PLAN_HEADING}")"
    [ "$(approval_verdict)" = no ]
    # A revised plan whose heading plan-status itself does not count still needs approving again.
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}")" \
        "$(issue_comment 2 someone COLLABORATOR "${keyword}")" \
        "$(issue_comment 3 planner COLLABORATOR "${PLAN_HEADING^^}")"
    [ "$(approval_verdict)" = no ]
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}")" \
        "$(issue_comment 2 someone COLLABORATOR "${keyword}")" \
        "$(issue_comment 3 planner COLLABORATOR "See the ##implementation plan above, revised")"
    [ "$(approval_verdict)" = no ]
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}")" \
        "$(issue_comment 2 planner COLLABORATOR "Revised."$'\n\n'"${PLAN_HEADING}")" \
        "$(issue_comment 3 someone COLLABORATOR "${keyword}")"
    [ "$(approval_verdict)" = yes ]
    # No plan at all: no.
    write_comments 7 "$(issue_comment 1 someone COLLABORATOR "${keyword}")"
    [ "$(approval_verdict)" = no ]
}

@test "issue plan-status --approval reads only the issue when no comment could approve, and the login and collaborators once each when one could" {
    local keyword
    keyword="$(sign_off_keywords | head -1)"
    write_issue 7 "A title" OPEN "The request."
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}")" \
        "$(issue_comment 2 someone COLLABORATOR "go ahead")" \
        "$(issue_comment 3 stranger NONE "${keyword}")"
    run_issue_read plan-status --issue 7 --approval
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"approved"$'\t'"no" ]]
    assert_one_issue_read 7 "${PLAN_STATUS_FIELDS}"

    prepare_approval
    : > "${GH_LOG}"
    write_comments 7 "$(issue_comment 1 planner COLLABORATOR "${PLAN_HEADING}")" \
        "$(issue_comment 2 someone COLLABORATOR "${keyword}")" \
        "$(issue_comment 3 credfeto OWNER "${keyword}")"
    run_issue_read plan-status --issue 7 --approval
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "issue view 7 --repo ${REPO} --json ${PLAN_STATUS_FIELDS} --jq ")" -eq 1 ]
    [ "$(grep -c '^api user ' "${GH_LOG}")" -eq 1 ]
    [ "$(grep -c "^api ${COLLABORATORS_ENDPOINT}" "${GH_LOG}")" -eq 1 ]
}

@test "issue plan-status --approval prints nothing, and exits 1, when the login or the collaborators cannot be read, never a no" {
    local keyword
    keyword="$(sign_off_keywords | head -1)"
    prepare_approval
    approval_of "${keyword}" > /dev/null
    fail_api "${COLLABORATORS_ENDPOINT}" "${PUSH_ACCESS_ERROR}"
    run_issue_read plan-status --issue 7 --approval
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: "* ]]
    rm -f "$(api_fixture "${COLLABORATORS_ENDPOINT}").fail"
    fail_api user
    run_issue_read plan-status --issue 7 --approval
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    # Without --approval none of that is read, and the answer is the same as ever.
    run_issue_read plan-status --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(plan_status_head yes no)"$'\n'"$(plan_lines 1 planner COLLABORATOR)"$'\n'"$(comment_line 2 someone COLLABORATOR yes)" ]
}

# The approval check lib/prompts printed for a repository with no board before #1772 (the jq of
# human_plan_approval_jq_literal for the bot login $1 and trusted logins $2), with its keywords
# built from pieces as in sign_off_keywords.
old_prompt_approval_jq() {
    local keywords
    keywords="$(sign_off_keywords | head -1)|go ahead|looks good|$(sign_off_keywords | tail -1)"
    # shellcheck disable=SC2016 # jq syntax ($c, $i, $login), not bash variables
    printf '%s' '(.comments) as $c | (first(range($c|length)|select($c[.].body|test("##\\s*Implementation Plan";"i"))) // -1) as $i | if $i>=0 then ($c[($i+1):]|map(select(.author.login as $login | $login != "'"$1"'" and ('"$2"'|index($login)) != null))|any(.[]; .body|test("\\b('"${keywords}"')\\b";"i"))) else false end'
}

@test "issue plan-status --approval never says yes to a comment the old prompt approval check refused" {
    local keyword body author association old new old_jq
    local -i accepted_by_old=0 refused_by_old=0
    prepare_approval
    # The old check trusted the owner and the collaborators (and two bots), as the orchestrator did.
    old_jq="$(old_prompt_approval_jq "${APPROVAL_AGENT}" '["credfeto","someone","planner","the-agent","copilot-pull-request-reviewer","github-advanced-security[bot]"]')"
    for keyword in $(sign_off_keywords); do
        for body in "${keyword}" "_${keyword}_" "not ${keyword} yet" "> ${keyword}" "plan_${keyword}" "go ahead" "nothing here" "${keyword}?"; do
            for author in "someone COLLABORATOR" "credfeto OWNER" "stranger NONE" "${APPROVAL_AGENT} COLLABORATOR" "planner COLLABORATOR" "copilot-pull-request-reviewer NONE"; do
                association="${author#* }"
                new="$(approval_of "${body}" "${author% *}" "${association}")"
                old="$(jq -e "${old_jq}" "$(issue_fixture 7).json" > /dev/null && echo yes || echo no)"
                if [ "${old}" = no ]; then
                    refused_by_old+=1
                    [ "${new}" = no ] || { echo "the old check refused, the new accepts: ${author}: ${body}" >&2; return 1; }
                else
                    accepted_by_old+=1
                fi
            done
        done
    done
    [ "${refused_by_old}" -gt 0 ] && [ "${accepted_by_old}" -gt 0 ]
}

# --- issue list and issue search ------------------------------------------------
# One issue as gh issue list --json gives it: its number $1 (JSON, so a test can give one that is
# not a number), state $2 and title $3, then its label names, then -- and its assignee logins.
issue_entry() {
    local number="$1" state="$2" title="$3"
    shift 3
    local -a labels=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        labels+=("$1")
        shift
    done
    [ "$#" -eq 0 ] || shift
    jq -n --argjson number "${number}" --arg state "${state}" --arg title "${title}" \
        --arg labels "$(printf '%s\037' "${labels[@]}")" --arg repo "${REPO}" --args \
        '{number: $number, state: $state, title: $title, url: "https://github.com/\($repo)/issues/\($number)",
          labels: ($labels | split("\u001f") | map(select(. != "") | {id: "LA_x", name: ., color: "ffffff", description: ""})),
          assignees: ($ARGS.positional | map({id: "U_x", login: ., name: ""}))}' "$@"
}

# Writes the issues of the repository, in the order given: each argument an issue_entry object.
# With no argument the repository has none.
write_issue_list() {
    printf '%s\n' "$@" | jq -s '.' > "${GH_FIXTURES}/issue-list.json"
}

# Writes $1 open issues, numbered from 1, with no label and no assignee.
write_numbered_issue_list() {
    jq -n --argjson count "$1" --arg repo "${REPO}" '[range(1; $count + 1) | {number: ., state: "OPEN",
        title: "issue \(.)", url: "https://github.com/\($repo)/issues/\(.)", labels: [], assignees: []}]' \
        > "${GH_FIXTURES}/issue-list.json"
}

run_issue_list() {
    run --separate-stderr "${SCRIPT}" issue list --repo "${REPO}" "$@"
}

run_issue_search() {
    run --separate-stderr "${SCRIPT}" issue search --repo "${REPO}" "$@"
}

@test "issue list and issue search help, from each -h, --help and help, gives the usage, the output, the limits and the exit codes, help issue gives both, and none calls gh" {
    local invocation
    for invocation in "issue list -h" "issue list --help" "issue list --repo ${REPO} --help" "help issue list"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${ISSUE_LIST_USAGE}"$'\n'* ]]
        [[ "${output}" == *$'\n'"  <number>  <priority>  <flags>  <assignees>  <title>  <labels>"$'\n'* ]]
        [[ "${output}" == *"exactly six tab-separated fields and none is empty"* ]]
        [[ "${output}" == *"--state, --label, --search, --limit, --assignee, --author, --json, --jq and --web are not"$'\n'"options"* ]]
        [[ "${output}" == *"  blocked  the issue has a label named Blocked, in any case"$'\n'"  on-hold  the issue has a label named On Hold or On-Hold, in any case"* ]]
        [[ "${output}" == *"At most 1000 issues are listed. More than that is a runtime failure and nothing is printed,"$'\n'"never part of the list."* ]]
        [[ "${output}" == *"Exit codes: 0 listed, an empty list included (nothing is printed); 1 a runtime failure"*"2 a usage error." ]]
        [[ "${output}" != *"cfwf issue search"* && "${output}" != *"cfwf issue view"* ]]
    done
    for invocation in "issue search -h" "issue search --help" "issue search --text x --help" "help issue search"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${ISSUE_SEARCH_USAGE}"$'\n'* ]]
        [[ "${output}" == *$'\n'"  <number>  <OPEN|CLOSED>  <title>  <labels>"$'\n'* ]]
        [[ "${output}" == *"exactly four tab-separated fields and none is empty"* ]]
        [[ "${output}" == *"printable ASCII, with no control character, and hold a letter or a digit."* ]]
        [[ "${output}" == *"so cfwf: add issue list searches for cfwf add issue"$'\n'"         list"* ]]
        [[ "${output}" == *"AND, OR and NOT are refused as whole words in upper case, the only case GitHub"$'\n'"         reads as search operators"* ]]
        [[ "${output}" == *"open, closed or all. The default is open."* ]]
        [[ "${output}" == *"from 1 to 100. The default is 30."* ]]
        [[ "${output}" == *"cfwf adds \"in:title,body\" before the words, so the search only looks in titles and bodies, and"$'\n'"gh adds the repository itself, so the search never leaves it. The words must be at most"$'\n'"256 characters, counted as they are sent. Both the text as given and the words are"$'\n'"also checked for a token, and the text for a host path"* ]]
        [[ "${output}" == *"in the order the search returned them, never re-sorted"* ]]
        [[ "${output}" == *"\"cfwf: warning: more than <n> issues match; only the first <n> are printed\", and the exit code is"$'\n'"still 0."* ]]
        [[ "${output}" == *"Search is eventually consistent"* ]]
        [[ "${output}" == *"a title tag such as tool(cfwf): is not matched by"$'\n'"the word cfwf"* ]]
        [[ "${output}" == *"Exit codes: 0 searched, no match included (nothing is printed); 8 the --text holds a token"*"2 a usage error, which names the rule --text"$'\n'"broke but never its value." ]]
        [[ "${output}" != *"Usage: cfwf issue list"* && "${output}" != *"Usage: cfwf issue view"* ]]
    done

    for invocation in "help issue" "issue -h" "issue --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf issue view ${ISSUE_READ_USAGE}"* ]]
        [[ "${output}" == *"Usage: cfwf issue plan-status ${ISSUE_READ_USAGE}"*$'\n\n'"${ISSUE_LIST_USAGE}"$'\n'*$'\n\n'"${ISSUE_SEARCH_USAGE}"$'\n'* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

# Given a run's status, stdout and stderr: it was a usage error of cfwf issue $4 with nothing on
# stdout and stderr exactly "cfwf: $5", a blank line and that subcommand's usage. The whole of
# stderr is compared, so a value echoed on any line of it fails.
assert_issue_usage_error() {
    local run_status="$1" run_output="$2" run_stderr="$3" subcommand="$4" rule="$5" usage
    usage="$("${SCRIPT}" help issue "${subcommand}")"
    [ "${run_status}" -eq 2 ] || { echo "exit ${run_status}, not 2" >&2; return 1; }
    [ -z "${run_output}" ]
    [ "${run_stderr}" = "cfwf: ${rule}"$'\n\n'"${usage}" ] || { printf 'expected the rule %s, got:\n%s\n' "${rule}" "${run_stderr}" >&2; return 1; }
}

@test "issue list usage errors exit 2 before any gh call, each with the issue list usage, never echoing a value" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    local unknown="unknown option (argument 5; its value is not shown)"
    # Each case is the arguments after --repo, a |, and the rule stderr gives.
    local -a cases=(
        "--repo ${REPO}|--repo can only be given once"
        "--state all|${unknown}"
        "--search ghp_secretvalue|${unknown}"
        "--limit 5|${unknown}"
        "--json number|${unknown}"
        "--jq .|${unknown}"
        "--label Bug|${unknown}"
        "--assignee someone|${unknown}"
        "--author someone|${unknown}"
        "--web|${unknown}"
        "--issue 1|${unknown}"
        "--text x|${unknown}"
        "extra|${unknown}"
    )
    local entry
    for entry in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_issue_list ${entry%%|*}
        assert_issue_usage_error "${status}" "${output}" "${stderr}" list "${entry#*|}" || { echo "case: ${entry%%|*}" >&2; return 1; }
    done

    run --separate-stderr "${SCRIPT}" issue list
    assert_issue_usage_error "${status}" "${output}" "${stderr}" list "missing required option --repo"

    local bad
    for bad in "./x" "x/.." "../.."; do
        run --separate-stderr "${SCRIPT}" issue list --repo "${bad}"
        assert_issue_usage_error "${status}" "${output}" "${stderr}" list "invalid value for --repo: neither the owner nor the repository can be . or .."
    done
    run --separate-stderr "${SCRIPT}" issue list --repo "not-a-repo"
    assert_issue_usage_error "${status}" "${output}" "${stderr}" list "invalid value for --repo: it must be <owner>/<repo>"
    [ ! -f "${GH_LOG}" ]
}

@test "issue list prints each open issue as six tab-separated fields, highest priority first and then by number, from one read of the open ones with no search" {
    write_issue_list "$(issue_entry 40 OPEN "no priority" Bug)" \
        "$(issue_entry 12 OPEN "low" Low -- someone)" \
        "$(issue_entry 3 OPEN "medium, in lower case" medium Enhancement -- credfeto someone)" \
        "$(issue_entry 30 OPEN "security" SECURITY)" \
        "$(issue_entry 7 OPEN "high and low, so high" Low High)" \
        "$(issue_entry 2 OPEN "no labels at all")" \
        "$(issue_entry 25 OPEN "urgent" Urgent)" \
        "$(issue_entry 8 OPEN "high" high)" \
        "$(issue_entry 9 CLOSED "a closed one" Security)"
    run_issue_list
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected
    expected="$(tab_row 30 Security - - "security" SECURITY)"$'\n'
    expected+="$(tab_row 25 Urgent - - "urgent" Urgent)"$'\n'
    expected+="$(tab_row 7 High - - "high and low, so high" Low,High)"$'\n'
    expected+="$(tab_row 8 High - - "high" high)"$'\n'
    expected+="$(tab_row 3 Medium - credfeto,someone "medium, in lower case" medium,Enhancement)"$'\n'
    expected+="$(tab_row 12 Low - someone "low" Low)"$'\n'
    expected+="$(tab_row 2 - - - "no labels at all" -)"$'\n'
    expected+="$(tab_row 40 - - - "no priority" Bug)"
    [ "${output}" = "${expected}" ]
    has_field_lines "${output}" 8 6

    # The --jq program spans lines of the log, so calls are counted by the lines that start one.
    [ "$(grep -cE '^(issue|pr|repo|api|project|label) ' "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "issue list --repo ${REPO} --state open --limit 1001 --json number,title,labels,assignees --jq ")" -eq 1 ]
    [ "$(gh_call_count "--search")" -eq 0 ]
}

@test "issue list flags blocked and on-hold, in that order, from labels in any case and either spelling of On Hold, and lists those issues" {
    write_issue_list "$(issue_entry 1 OPEN "blocked" Blocked)" \
        "$(issue_entry 2 OPEN "on hold" "On Hold")" \
        "$(issue_entry 3 OPEN "on-hold" ON-HOLD)" \
        "$(issue_entry 4 OPEN "both" "on hold" BLOCKED)" \
        "$(issue_entry 5 OPEN "neither" Blocked-by-upstream "On Holding" "Hold")" \
        "$(issue_entry 6 OPEN "both spellings" "On Hold" "on-hold" blocked)" \
        "$(issue_entry 7 OPEN "upper case" "ON HOLD")" \
        "$(issue_entry 8 OPEN "mixed case" "on-Hold" "bLoCkEd")" \
        "$(issue_entry 9 OPEN "other spellings" On_Hold OnHold "On  Hold" "Blocked " Unblocked)"
    run_issue_list
    [ "${status}" -eq 0 ]
    local expected=$'1\tblocked\n2\ton-hold\n3\ton-hold\n4\tblocked,on-hold\n5\t-\n6\tblocked,on-hold'
    expected+=$'\n7\ton-hold\n8\tblocked,on-hold\n9\t-'
    [ "$(cut -f 1,3 <<< "${output}")" = "${expected}" ]
    has_field_lines "${output}" 9 6
}

@test "issue list and issue plan-status agree on which labels make an issue Blocked, from the one definition both use" {
    local label flag blocked
    for label in Blocked blocked BLOCKED Blocked-by-upstream Unblocked "On Hold" On-Hold; do
        case "${label,,}" in
            blocked) flag=blocked blocked=yes ;;
            "on hold" | on-hold) flag=on-hold blocked=no ;;
            *) flag=- blocked=no ;;
        esac
        write_issue_list "$(issue_entry 7 OPEN "A title" "${label}")"
        run_issue_list
        [ "${status}" -eq 0 ]
        [ "$(cut -f 3 <<< "${output}")" = "${flag}" ] || { echo "list ${label}: ${output}" >&2; return 1; }
        write_issue 7 "A title" OPEN "The request." "${label}"
        run_issue_read plan-status --issue 7
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(plan_status_head no "${blocked}")" ] || { echo "plan-status ${label}: ${output}" >&2; return 1; }
    done
}

@test "issue list prints nothing and exits 0 when there is no open issue" {
    write_issue_list "$(issue_entry 9 CLOSED "a closed one" High)"
    run_issue_list
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    # run drops trailing newlines, so the bytes are counted: an empty list is no output at all.
    [ "$("${SCRIPT}" issue list --repo "${REPO}" | wc -c)" -eq 0 ]
}

@test "issue list keeps a title or a label with a tab, a newline, a carriage return, a control character or a whole forged row on one line of six fields" {
    local forged=$'99\tSecurity\t-\tcredfeto\tforged\tSecurity'
    write_issue_list "$(issue_entry 1 OPEN $'a\ttitle\nwith\r\nbreaks' $'Lab\tel' $'line\nbreak')" \
        "$(issue_entry 2 OPEN "real"$'\n'"${forged}" "real"$'\n'"${forged}")" \
        "$(issue_entry 3 OPEN $'\t\n\x1b')" \
        "$(issue_entry 4 OPEN "")" \
        "$(issue_entry 5 OPEN $'a\x1b[1mb\xc2\x9b31mc\xc2\x85d\x7fe\xc2\xa0f' $'x\xc2\x9by' $'High\x7f')"
    run_issue_list
    [ "${status}" -eq 0 ]
    has_field_lines "${output}" 5 6
    local expected
    expected="$(tab_row 1 - - - "a title with  breaks" "Lab el,line break")"$'\n'
    expected+="$(tab_row 2 - - - "real ${forged//$'\t'/ }" "real ${forged//$'\t'/ }")"$'\n'
    expected+="$(tab_row 3 - - - "   " -)"$'\n'
    expected+="$(tab_row 4 - - - - -)"$'\n'
    expected+="$(tab_row 5 - - - "a [1mb 31mc d e"$'\xc2\xa0'"f" "x y,High ")"
    [ "${output}" = "${expected}" ]
}

@test "issue list prints exactly 1000 issues, and with more open prints none and exits 1" {
    write_numbered_issue_list 1000
    run_issue_list
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    has_field_lines "${output}" 1000 6
    [ "${output%%$'\n'*}" = "$(tab_row 1 - - - "issue 1" -)" ]
    [ "${output##*$'\n'}" = "$(tab_row 1000 - - - "issue 1000" -)" ]

    write_numbered_issue_list 1001
    run_issue_list
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO} has more than 1000 open issues, so none is printed" ]
}

@test "issue list prints nothing and exits 1 when gh's answer is not a count and that many rows of six fields" {
    local row
    row="$(tab_row 5 High - - "a title" High)"
    local -a answers=(
        ""
        "x"
        "one"$'\n'"${row}"
        "-1"$'\n'"${row}"
        "99999999999999999999"$'\n'"${row}"
        "${row}"
        "2"$'\n'"${row}"
        "0"$'\n'"${row}"
        "1"$'\n'"${row}"$'\n'"${row}"
        "1"
        "1"$'\n'"x${row}"
        "1"$'\n'"${row#5}"
        "1"$'\n'"$(tab_row 5 high - - "a title" High)"
        "1"$'\n'"$(tab_row 5 High stale - "a title" High)"
        "1"$'\n'"$(tab_row 5 High on-hold,blocked - "a title" High)"
        "1"$'\n'"$(tab_row 5 High - - "" High)"
        "1"$'\n'"$(tab_row 5 High - - "a title")"
        "1"$'\n'"$(tab_row 5 High - - "a title" High extra)"
        "2"$'\n\n'"${row}"
    )
    local answer
    for answer in "${answers[@]}"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/issue-list.out"
        run_issue_list
        [ "${status}" -eq 1 ] || { printf 'accepted: %q (%s)\n' "${answer}" "${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "${ISSUE_LIST_UNEXPECTED}" ]
    done

    printf '1\n%s\n' "${row}" > "${GH_FIXTURES}/issue-list.out"
    run_issue_list
    [ "${status}" -eq 0 ]
    [ "${output}" = "${row}" ]

    # A number that is not one, as the filter itself prints it.
    rm -f "${GH_FIXTURES}/issue-list.out"
    write_issue_list "$(issue_entry 5 OPEN "a title")" "$(issue_entry '"6x"' OPEN "a title")"
    run_issue_list
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ISSUE_LIST_UNEXPECTED}" ]
}

@test "issue list treats a failed read, or a repository that is not found, as a runtime failure (exit 1), never as an empty list" {
    write_issue_list
    printf '%s\n' "gh: Bad Gateway (HTTP 502)" "a second line" > "${GH_FIXTURES}/issue-list.fail"
    run_issue_list
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the open issues of ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    printf '%s\n' "GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" > "${GH_FIXTURES}/issue-list.fail"
    run_issue_list
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the open issues of ${REPO}: GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" ]
}

@test "issue list and issue search fail (exit 1) when gh is not installed, after the options are checked" {
    mkdir -p "${TEST_TMP}/empty-path"
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" issue list --repo "${REPO}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" issue list --repo "${REPO}" --state all
    [ "${status}" -eq 2 ]

    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" issue search --repo "${REPO}" --text words
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" issue search --repo "${REPO}" --text "a OR b"
    [ "${status}" -eq 2 ]
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" issue search --repo "${REPO}" --text "ghp_abc123"
    [ "${status}" -eq 8 ]
}

@test "issue search usage errors exit 2 before any gh call, each with the issue search usage" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    local unknown="unknown option (argument 7; its value is not shown)"
    # Each case is the arguments after --repo, a |, and the rule stderr gives.
    local -a cases=(
        "|missing required option --text"
        "--repo ${REPO} --text x|--repo can only be given once"
        "--text x --text y|--text can only be given once"
        "--text x --state open --state all|--state can only be given once"
        "--text x --limit 5 --limit 6|--limit can only be given once"
        "--text x --state|--state needs a value"
        "--text|--text needs a value"
        "--text x --json number|${unknown}"
        "--text x --jq .|${unknown}"
        "--text x --search ghp_secretvalue|${unknown}"
        "--text x --label Bug|${unknown}"
        "--text x --author someone|${unknown}"
        "--text x --assignee someone|${unknown}"
        "--text x --web|${unknown}"
        "--text x --issue 1|${unknown}"
        "--text x extra|${unknown}"
    )
    local entry
    for entry in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_issue_search ${entry%%|*}
        assert_issue_usage_error "${status}" "${output}" "${stderr}" search "${entry#*|}" || { echo "case: ${entry%%|*}" >&2; return 1; }
    done

    run --separate-stderr "${SCRIPT}" issue search --text x
    assert_issue_usage_error "${status}" "${output}" "${stderr}" search "missing required option --repo"
    # --repo is required before --text, so with neither it is --repo that is named.
    run --separate-stderr "${SCRIPT}" issue search
    assert_issue_usage_error "${status}" "${output}" "${stderr}" search "missing required option --repo"
    local bad
    for bad in OPEN merged "" "open closed"; do
        run_issue_search --text x --state "${bad}"
        assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --state: it must be open, closed or all" || { echo "--state ${bad}" >&2; return 1; }
    done
    for bad in 0 000 101 0101 99999999999999999999999 x -1 1.5 ""; do
        run_issue_search --text x --limit "${bad}"
        assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --limit: it must be a number from 1 to 100" || { echo "--limit ${bad}" >&2; return 1; }
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue search refuses a --text that is not printable ASCII, has no letter or digit, or holds an operator, naming the rule and never the value, before any gh call" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    local charset="invalid value for --text: it must be printable ASCII, with no control character"
    local text
    # A control character or a byte above ASCII is refused rather than sent as a space: GitHub does
    # not split words on it, so a space would cut a word in two.
    for text in $'a\tb' $'a\nb' $'a\rb' $'a\x1bb' $'a\x7fb' $'caf\xc3\xa9' $'a\xc2\xa0b' $'a\xffb'; do
        run_issue_search --text "${text}"
        assert_issue_usage_error "${status}" "${output}" "${stderr}" search "${charset}" || { printf 'text: %q\n' "${text}" >&2; return 1; }
    done
    # The character set is checked first: a text that also has no letter, or holds an operator, or
    # is too long, or holds a token, is refused under it.
    for text in $'\t' $'a OR\tb' $'ghp_abc123\tx' "$(head -c 300 < /dev/zero | tr '\0' a)"$'\t'; do
        run_issue_search --text "${text}"
        assert_issue_usage_error "${status}" "${output}" "${stderr}" search "${charset}" || { printf 'text: %q\n' "${text}" >&2; return 1; }
    done
    for text in "" " " "   " "-" "." "#" "'" "_" "- . # ' _" ":" '""' "()" ":::" "*" "@" "/ , ;"; do
        run_issue_search --text "${text}"
        assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --text: it must hold a letter or a digit" || { printf 'text: %q\n' "${text}" >&2; return 1; }
    done
    # The operator check is made on the words sent, so punctuation turned into a space round an
    # operator does not hide it, and it comes before the length and token checks. Only the upper-case
    # forms are operators to GitHub, so only they are refused, and a leading - does not hide one.
    for text in "OR" "a OR b" "a AND b" "NOT a" "x -NOT" "-OR" "it's OR" "AND" "a OR repo-marker" \
        "a:OR" "OR:x" "(a OR b)" "repo:x OR y" "x(NOT)" '"a"AND"b"' "ghp_abc123 OR x" "$(head -c 300 < /dev/zero | tr '\0' a) OR"; do
        run_issue_search --text "${text}"
        assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --text: it must not hold AND, OR or NOT, which are search operators" || { printf 'text: %q\n' "${text}" >&2; return 1; }
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue search sends each character other than a letter, a digit, a space and - _ . # ' as a space, with one space between words, so a title is searched as it is and no qualifier, phrase or group reaches gh" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    # Each text as given, then the words gh is given after in:title,body.
    local -a given=(
        "cfwf: add issue list" "tool(cfwf): x" "fix(cfwf/issue): refuse a, b and c"
        "repo:other/x" "is:pr" "author:x" "org:other" "in:comments x" "a repo:other/x b" "user:@me"
        '"a phrase"' "(a" "a)" "[a]" "{a}" "a*" "a/b" "a@b" "a=b" "a<b" "a>b" "a,b" "a+b" "a;b" "a|b" 'a\b' "a~b"
        "a!b" "a\$b" "a%b" "a&b" "a?b" "\`a\`" "created:>=2020-01-01..2020-12-31" "  a  ::  b  " "a(-b)" "it's: fix #12"
    )
    local -a sent=(
        "cfwf add issue list" "tool cfwf x" "fix cfwf issue refuse a b and c"
        "repo other x" "is pr" "author x" "org other" "in comments x" "a repo other x b" "user me"
        "a phrase" "a" "a" "a" "a" "a" "a b" "a b" "a b" "a b" "a b" "a b" "a b" "a b" "a b" "a b" "a b"
        "a b" "a b" "a b" "a b" "a b" "a" "created 2020-01-01..2020-12-31" "a b" "a -b" "it's fix #12"
    )
    [ "${#given[@]}" -eq "${#sent[@]}" ]
    local index
    for index in "${!given[@]}"; do
        rm -f "${GH_LOG}"
        run_issue_search --text "${given[index]}"
        [ "${status}" -eq 0 ] || { printf 'refused: %q (%s) %s\n' "${given[index]}" "${status}" "${stderr}" >&2; return 1; }
        [ "${output}" = "$(tab_row 5 OPEN "a title" -)" ]
        [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
        [ "$(gh_call_count "issue list --repo ${REPO} --state open --search ${SEARCH_PREFIX} ${sent[index]} --limit 31 ")" -eq 1 ] \
            || { printf 'given %q, gh got: %s\n' "${given[index]}" "$(cat "${GH_LOG}")" >&2; return 1; }
    done
}

@test "issue search takes words that only hold and, or or not inside them, a leading -, a # and an apostrophe, and passes each as it is" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    local text
    for text in notable order cannot "don't" "-foo" "#123" "a_b.c" "Android oregano" "and_or" "1535"; do
        run_issue_search --text "${text}"
        [ "${status}" -eq 0 ] || { printf 'refused: %q (%s) %s\n' "${text}" "${status}" "${stderr}" >&2; return 1; }
        [ "${output}" = "$(tab_row 5 OPEN "a title" -)" ]
        [ "$(gh_call_count "--search ${SEARCH_PREFIX} ${text} --limit")" -eq 1 ]
    done
}

@test "issue search takes AND, OR and NOT joined to other letters by a character the words keep, as one plain word, and passes each as it is" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    local text
    for text in "OR-tools upgrade" "NOT-FOUND error" "v1.OR.2" "a.OR.b" "x-AND-y" "OR's fix" "it's-NOT" "'OR'" "AND_OR" \
        "-NOT-FOUND" "NOT."; do
        run_issue_search --text "${text}"
        [ "${status}" -eq 0 ] || { printf 'refused: %q (%s) %s\n' "${text}" "${status}" "${stderr}" >&2; return 1; }
        [ "${output}" = "$(tab_row 5 OPEN "a title" -)" ]
        [ "$(gh_call_count "--search ${SEARCH_PREFIX} ${text} --limit")" -eq 1 ]
    done
}

@test "issue search takes and, or and not as whole words in lower or mixed case, which GitHub reads as plain words, and passes each as it is" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    local text
    for text in "cannot read or write config" "token not refreshed" "a and b" "Not a" "nOt" "x -not" "a.or.b" "it's or" \
        "x-and-y" "And Or Not" "oR aNd NoT"; do
        run_issue_search --text "${text}"
        [ "${status}" -eq 0 ] || { printf 'refused: %q (%s) %s\n' "${text}" "${status}" "${stderr}" >&2; return 1; }
        [ "${output}" = "$(tab_row 5 OPEN "a title" -)" ]
        [ "$(gh_call_count "--search ${SEARCH_PREFIX} ${text} --limit")" -eq 1 ]
    done
}

@test "issue search takes a --text of up to 256 characters, counting the words alone, and refuses one character over" {
    write_issue_list
    local fits long_repo
    # Only the words are counted, never the qualifiers cfwf and gh add, so 256 characters of words
    # are passed on whole even with a long repository name.
    fits="$(head -c 256 < /dev/zero | tr '\0' a)"
    run_issue_search --text "${fits}"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "--search ${SEARCH_PREFIX} ${fits} --limit")" -eq 1 ]
    long_repo="$(head -c 39 < /dev/zero | tr '\0' o)/$(head -c 60 < /dev/zero | tr '\0' r)"
    run --separate-stderr "${SCRIPT}" issue search --repo "${long_repo}" --text "${fits}"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "issue list --repo ${long_repo} --state open --search ${SEARCH_PREFIX} ${fits} --limit")" -eq 1 ]

    rm -f "${GH_LOG}"
    run_issue_search --text "${fits}b"
    assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --text: it is too long: it must be at most 256 characters"
    # The length is checked before the token: a text that is both is a usage error, not exit 8.
    run_issue_search --text "ghp_${fits}"
    assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --text: it is too long: it must be at most 256 characters"
    # It is the words sent that are counted: punctuation sent as a space, and the spaces collapsed
    # round it, take nothing from the limit, but a character sent as a space between words counts.
    run_issue_search --text "${fits}:b"
    assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --text: it is too long: it must be at most 256 characters"
    run_issue_search --text "$(head -c 255 < /dev/zero | tr '\0' a): b"
    assert_issue_usage_error "${status}" "${output}" "${stderr}" search "invalid value for --text: it is too long: it must be at most 256 characters"
    [ ! -f "${GH_LOG}" ]
    run_issue_search --text "::  ${fits}  ::"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "--search ${SEARCH_PREFIX} ${fits} --limit")" -eq 1 ]
    rm -f "${GH_LOG}"
    run_issue_search --text "$(printf 'a: %.0s' {1..100})"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "--search ${SEARCH_PREFIX} $(printf 'a %.0s' {1..99})a --limit")" -eq 1 ]
    rm -f "${GH_LOG}"
    [ ! -f "${GH_LOG}" ]
}

@test "issue search refuses a --text holding a token or a host path (exit 8), never echoing it, before any gh call" {
    write_issue_list "$(issue_entry 5 OPEN "a title")"
    local text
    # Both the text as given and the words sent are checked: punctuation sent as a space can hide a
    # token's shape in the words (the URL and the header) or form it there (the last two).
    for text in "ghp_abc123" "find ghp_abc123 here" "github_pat_x" "glpat-abc" "Bearer abcdefghij0123456789xyz" \
        "ghp_abc123:x" "(ghp_abc123)" "https://user:s3cret@example.com" "Authorization: Bearer abcdefghij0123456789xyz" \
        "Bearer(abcdefghij0123456789xyz)" "-----BEGIN(RSA)PRIVATE KEY-----"; do
        run_issue_search --text "${text}"
        [ "${status}" -eq 8 ] || { printf 'accepted: %q (%s)\n' "${text}" "${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: text refused: token" ]
    done
    # A host path is refused too, now that / can be given, though it is sent as words.
    for text in "/home/someone/x" "see /tmp/a" "C:\\Users\\someone"; do
        run_issue_search --text "${text}"
        [ "${status}" -eq 8 ] || { printf 'accepted: %q (%s)\n' "${text}" "${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: text refused: host path" ]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue search asks gh for the repository's issues matching in:title,body and the words, with no repo: of its own, open by default, one more than --limit (30 by default)" {
    write_issue_list "$(issue_entry 5 OPEN "an open one" Bug)" "$(issue_entry 6 CLOSED "a closed one")"
    run_issue_search --text "widget fails"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(tab_row 5 OPEN "an open one" Bug)" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "issue list --repo ${REPO} --state open --search ${SEARCH_PREFIX} widget fails --limit 31 --json number,state,title,labels --jq ")" -eq 1 ]
    # gh adds repo: itself, so cfwf never sends one.
    [ "$(gh_call_count "repo:")" -eq 0 ]

    run_issue_search --text "widget" --state closed --limit 007
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row 6 CLOSED "a closed one" -)" ]
    [ "$(gh_call_count "issue list --repo ${REPO} --state closed --search ${SEARCH_PREFIX} widget --limit 8 --json ")" -eq 1 ]

    run_issue_search --limit 100 --state all --text "widget"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row 5 OPEN "an open one" Bug)"$'\n'"$(tab_row 6 CLOSED "a closed one" -)" ]
    [ "$(gh_call_count "issue list --repo ${REPO} --state all --search ${SEARCH_PREFIX} widget --limit 101 --json ")" -eq 1 ]
    has_field_lines "${output}" 2 4
}

@test "issue search prints the issues in the order the search returned them, never re-sorted" {
    write_issue_list "$(issue_entry 9 OPEN "nine" Low)" "$(issue_entry 3 CLOSED "three" Security Bug)" \
        "$(issue_entry 12 OPEN "twelve" -- someone)"
    run_issue_search --text words --state all
    [ "${status}" -eq 0 ]
    local expected
    expected="$(tab_row 9 OPEN "nine" Low)"$'\n'
    expected+="$(tab_row 3 CLOSED "three" Security,Bug)"$'\n'
    expected+="$(tab_row 12 OPEN "twelve" -)"
    [ "${output}" = "${expected}" ]
    has_field_lines "${output}" 3 4
}

@test "issue search prints the first --limit of more matches with a warning and exit 0, exactly --limit without one, and nothing for no match" {
    write_issue_list "$(issue_entry 1 OPEN "one")" "$(issue_entry 2 OPEN "two")" "$(issue_entry 3 OPEN "three")" "$(issue_entry 4 OPEN "four")"
    run_issue_search --text words --limit 2
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row 1 OPEN one -)"$'\n'"$(tab_row 2 OPEN two -)" ]
    [ "${stderr}" = "${SEARCH_WARNING_OF_2}" ]

    write_issue_list "$(issue_entry 1 OPEN "one")" "$(issue_entry 2 OPEN "two")" "$(issue_entry 3 OPEN "three")"
    run_issue_search --text words --limit 2
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row 1 OPEN one -)"$'\n'"$(tab_row 2 OPEN two -)" ]
    [ "${stderr}" = "${SEARCH_WARNING_OF_2}" ]

    write_issue_list "$(issue_entry 1 OPEN "one")" "$(issue_entry 2 OPEN "two")"
    run_issue_search --text words --limit 2
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row 1 OPEN one -)"$'\n'"$(tab_row 2 OPEN two -)" ]
    [ -z "${stderr}" ]

    write_issue_list
    run_issue_search --text words
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    [ "$("${SCRIPT}" issue search --repo "${REPO}" --text words | wc -c)" -eq 0 ]
}

@test "issue search keeps a title or a label with a tab, a newline, a control character or a whole forged row on one line of four fields" {
    local forged=$'99\tOPEN\tforged\tSecurity'
    write_issue_list "$(issue_entry 1 OPEN $'a\ttitle\nwith\r\nbreaks' $'Lab\tel' $'line\nbreak')" \
        "$(issue_entry 2 CLOSED "real"$'\n'"${forged}" "real"$'\n'"${forged}")" \
        "$(issue_entry 3 OPEN "")" \
        "$(issue_entry 4 OPEN $'a\x1b[1mb\xc2\x9b31mc\xc2\x85d\x7fe\xc2\xa0f' $'x\xc2\x9by')"
    run_issue_search --text words --state all
    [ "${status}" -eq 0 ]
    has_field_lines "${output}" 4 4
    local expected
    expected="$(tab_row 1 OPEN "a title with  breaks" "Lab el,line break")"$'\n'
    expected+="$(tab_row 2 CLOSED "real ${forged//$'\t'/ }" "real ${forged//$'\t'/ }")"$'\n'
    expected+="$(tab_row 3 OPEN - -)"$'\n'
    expected+="$(tab_row 4 OPEN "a [1mb 31mc d e"$'\xc2\xa0'"f" "x y")"
    [ "${output}" = "${expected}" ]
}

@test "issue search prints nothing and exits 1 when gh's answer is not a count and that many rows of four fields, the second a state" {
    local row
    row="$(tab_row 5 OPEN "a title" Bug)"
    local -a answers=(
        ""
        "x"
        "-1"$'\n'"${row}"
        "${row}"
        "2"$'\n'"${row}"
        "0"$'\n'"${row}"
        "1"$'\n'"${row}"$'\n'"${row}"
        "1"
        "1"$'\n'"x${row}"
        "1"$'\n'"$(tab_row 5 MERGED "a title" Bug)"
        "1"$'\n'"$(tab_row 5 open "a title" Bug)"
        "1"$'\n'"$(tab_row 5 OPEN "" Bug)"
        "1"$'\n'"$(tab_row 5 OPEN "a title")"
        "1"$'\n'"$(tab_row 5 OPEN "a title" Bug extra)"
        "4"$'\n'"${row}"$'\n'"${row}"$'\n'"${row}"$'\n'"${row}"
    )
    local answer
    for answer in "${answers[@]}"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/issue-list.out"
        run_issue_search --text words --limit 2
        [ "${status}" -eq 1 ] || { printf 'accepted: %q (%s)\n' "${answer}" "${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "${ISSUE_SEARCH_UNEXPECTED}" ]
    done

    printf '3\n%s\n%s\n%s\n' "${row}" "${row}" "${row}" > "${GH_FIXTURES}/issue-list.out"
    run_issue_search --text words --limit 2
    [ "${status}" -eq 0 ]
    [ "${output}" = "${row}"$'\n'"${row}" ]
    [ "${stderr}" = "${SEARCH_WARNING_OF_2}" ]
}

@test "issue search treats a failed read, or a repository that is not found, as a runtime failure (exit 1), never as no match" {
    write_issue_list
    printf '%s\n' "gh: Bad Gateway (HTTP 502)" "a second line" > "${GH_FIXTURES}/issue-list.fail"
    run_issue_search --text words
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not search the issues of ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    printf '%s\n' "GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" > "${GH_FIXTURES}/issue-list.fail"
    run_issue_search --text words
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not search the issues of ${REPO}: GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" ]
}

# --- issue reopen ----------------------------------------------------------------

REOPEN_ISSUE=1346
REOPEN_ISSUE_URL="https://github.com/${REPO}/issues/${REOPEN_ISSUE}"

run_issue_reopen() {
    run --separate-stderr "${SCRIPT}" issue reopen --repo "${REPO}" --issue "${REOPEN_ISSUE}" "$@"
}

prepare_issue_reopen() {
    write_issue "${REOPEN_ISSUE}" "fix: something" "${1:-CLOSED}" "The body."
    printf '%s#issuecomment-77\n' "${REOPEN_ISSUE_URL}" > "${GH_FIXTURES}/comment.out"
    printf 'Reopened: the fix was reverted.\n' > "${TEST_TMP}/reason.md"
}

@test "issue reopen reopens a closed issue and prints its URL and new state, posting no comment without --body-file" {
    prepare_issue_reopen
    run_issue_reopen
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${REOPEN_ISSUE_URL} open" ]
    [ "$(gh_call_count "issue reopen ${REOPEN_ISSUE} --repo ${REPO}")" -eq 1 ]
    [ "$(gh_call_count "issue comment")" -eq 0 ]
}

@test "issue reopen posts the checked --body-file as a comment first, then reopens" {
    prepare_issue_reopen
    run_issue_reopen --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${REOPEN_ISSUE_URL} open" ]
    cmp "${TEST_TMP}/reason.md" "${GH_FIXTURES}/comment-body.txt"
    [ "$(gh_line_of "issue comment ${REOPEN_ISSUE}")" -lt "$(gh_line_of "issue reopen ${REOPEN_ISSUE}")" ]
}

@test "issue reopen leaves an open issue alone, the comment included, and says so" {
    prepare_issue_reopen OPEN
    run_issue_reopen --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${REOPEN_ISSUE_URL} already open" ]
    [ "$(gh_call_count "issue reopen")" -eq 0 ]
    [ "$(gh_call_count "issue comment")" -eq 0 ]
}

@test "issue reopen refuses (exit 8) a body with a leak or a plan-approval keyword before reading or writing anything" {
    prepare_issue_reopen
    write_leak_body "token ghp_$(printf 'a%.0s' {1..36})"
    run_issue_reopen --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    printf '  Approved\n' > "${TEST_TMP}/approved.md"
    run_issue_reopen --body-file "${TEST_TMP}/approved.md"
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: approval keyword"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue reopen exits 9 for a number that is no issue or is a pull request's, writing nothing" {
    run_issue_reopen
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${REOPEN_ISSUE} was not found" ]
    jq -n --arg url "https://github.com/${REPO}/pull/${REOPEN_ISSUE}" '{url: $url, state: "CLOSED"}' > "$(issue_fixture "${REOPEN_ISSUE}").json"
    run_issue_reopen
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${REOPEN_ISSUE} is a pull request, not an issue" ]
    [ "$(gh_call_count "issue reopen")" -eq 0 ]
}

@test "issue reopen fails (exit 1) naming that the comment was posted when the reopen itself fails" {
    prepare_issue_reopen
    echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/state-change.fail"
    run_issue_reopen --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: could not reopen ${REPO}#${REOPEN_ISSUE} (the comment was posted): "* ]]
    [ -z "${output}" ]
}

@test "issue reopen usage errors exit 2 before any gh call" {
    run --separate-stderr "${SCRIPT}" issue reopen --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --issue"* ]]
    run --separate-stderr "${SCRIPT}" issue reopen --issue 1
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" issue reopen --repo "${REPO}" --issue 0
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" issue reopen --repo "${REPO}" --issue 1 --body "x"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

# --- pr close and pr reopen ------------------------------------------------------

STATE_PR=1700
STATE_PR_URL="https://github.com/${REPO}/pull/${STATE_PR}"

# Writes the fixtures of a pr close or pr reopen run: the pull request in the state $1 (open or
# closed), merged $2 (false by default), opened by $3 (the agent by default) of the account type $4
# (User by default), with one commit by $5 (the agent by default). There is no fixture for the
# agent's login: pr close and pr reopen have no ownership rule, so they never read it.
prepare_pr_state() {
    local state="$1" merged="${2:-false}" author="${3:-${AGENT}}" type="${4:-User}" committer="${5:-${AGENT}}"
    jq -n --arg author "${author}" --arg type "${type}" --arg url "${STATE_PR_URL}" --arg state "${state}" --argjson merged "${merged}" \
        '{number: 1700, user: {login: $author, type: $type}, html_url: $url, commits: 1, state: $state, merged: $merged}' \
        | write_api "repos/${REPO}/pulls/${STATE_PR}"
    jq -n --arg login "${committer}" '[{sha: "abc", author: {login: $login}}]' | write_api "repos/${REPO}/pulls/${STATE_PR}/commits"
    printf '%s#issuecomment-88\n' "${STATE_PR_URL}" > "${GH_FIXTURES}/comment.out"
    printf 'Superseded by a newer pull request.\n' > "${TEST_TMP}/reason.md"
}

run_pr_state() {
    run --separate-stderr "${SCRIPT}" pr "$1" --repo "${REPO}" --pr "${STATE_PR}" "${@:2}"
}

@test "pr close closes the agent's own open pull request without merging it or deleting its branch, and prints its URL and new state" {
    prepare_pr_state open
    run_pr_state close
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${STATE_PR_URL} closed" ]
    grep -qxF "pr close ${STATE_PR} --repo ${REPO}" "${GH_LOG}"
    [ "$(gh_call_count "--delete-branch")" -eq 0 ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
}

@test "pr close posts the checked --body-file as a comment first, then closes" {
    prepare_pr_state open
    run_pr_state close --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${STATE_PR_URL} closed" ]
    cmp "${TEST_TMP}/reason.md" "${GH_FIXTURES}/comment-body.txt"
    [ "$(gh_line_of "pr comment ${STATE_PR}")" -lt "$(gh_line_of "pr close ${STATE_PR}")" ]
}

@test "pr close leaves a closed pull request alone and pr reopen an open one, the comment included" {
    prepare_pr_state closed
    run_pr_state close --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${STATE_PR_URL} already closed" ]
    prepare_pr_state open
    run_pr_state reopen --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${STATE_PR_URL} already open" ]
    [ "$(gh_call_count "pr close")" -eq 0 ]
    [ "$(gh_call_count "pr reopen")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
}

@test "pr reopen reopens the agent's own closed pull request" {
    prepare_pr_state closed
    run_pr_state reopen
    [ "${status}" -eq 0 ]
    [ "${output}" = "${STATE_PR_URL} open" ]
    grep -qxF "pr reopen ${STATE_PR} --repo ${REPO}" "${GH_LOG}"
}

@test "pr close and pr reopen refuse (exit 8) a merged pull request, writing nothing" {
    prepare_pr_state closed true
    run_pr_state close --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: close refused: the pull request is merged" ]
    run_pr_state reopen
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: reopen refused: the pull request is merged" ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
    [ "$(gh_call_count "pr close")" -eq 0 ]
    [ "$(gh_call_count "pr reopen")" -eq 0 ]
}

@test "pr close and pr reopen act on a pull request a person opened, without reading the agent's login or the commits" {
    prepare_pr_state open false credfeto User credfeto
    run_pr_state close --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${STATE_PR_URL} closed" ]
    cmp "${TEST_TMP}/reason.md" "${GH_FIXTURES}/comment-body.txt"
    grep -qxF "pr close ${STATE_PR} --repo ${REPO}" "${GH_LOG}"

    prepare_pr_state closed false someone-else User someone-else
    run_pr_state reopen
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${STATE_PR_URL} open" ]
    grep -qxF "pr reopen ${STATE_PR} --repo ${REPO}" "${GH_LOG}"
    [ "$(gh_call_count "api user")" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/${STATE_PR}/commits")" -eq 0 ]
}

# Makes the pull request of prepare_pr_state have $1 commits, listed as one for each further
# argument, each the login of that commit's author ("" for none).
write_state_pr_commits() {
    local count="$1"
    shift
    jq --argjson count "${count}" '.commits = $count' < "$(api_fixture "repos/${REPO}/pulls/${STATE_PR}").json" > "${TEST_TMP}/pull.json"
    write_api "repos/${REPO}/pulls/${STATE_PR}" < "${TEST_TMP}/pull.json"
    printf '%s\n' "$@" \
        | jq -R -s 'split("\n")[:-1] | map(if . == "" then {sha: "abc", author: null} else {sha: "abc", author: {login: .}} end)' \
        | write_api "repos/${REPO}/pulls/${STATE_PR}/commits"
}

@test "pr close and pr reopen act on a bot's pull request with commits by people, by an author GitHub does not know, none by the agent, or more than GitHub lists, without reading the commits" {
    prepare_pr_state open false prpixie User
    write_state_pr_commits 21 "${AGENT}" "${AGENT}" "${AGENT}" credfeto credfeto ""
    run_pr_state close
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${STATE_PR_URL} closed" ]

    prepare_pr_state closed false "dependabot[bot]" Bot credfeto
    run_pr_state reopen --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${STATE_PR_URL} open" ]
    cmp "${TEST_TMP}/reason.md" "${GH_FIXTURES}/comment-body.txt"
    [ "$(gh_line_of "pr comment ${STATE_PR}")" -lt "$(gh_line_of "pr reopen ${STATE_PR}")" ]

    prepare_pr_state open false prpixie User credfeto
    write_state_pr_commits 251 credfeto
    run_pr_state close
    [ "${status}" -eq 0 ]
    [ "${output}" = "${STATE_PR_URL} closed" ]
    [ "$(gh_call_count "pr close ${STATE_PR} --repo ${REPO}")" -eq 2 ]
    [ "$(gh_call_count "api user")" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/${STATE_PR}/commits")" -eq 0 ]
}

@test "pr close exits 9 for a pull request that does not exist, and refuses a body with a leak (exit 8) before reading it" {
    jq -n '{id: 1}' | write_api "repos/${REPO}"
    run_pr_state close
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#${STATE_PR} was not found" ]
    rm -f "${GH_LOG}"
    write_leak_body "token ghp_$(printf 'a%.0s' {1..36})"
    run_pr_state close --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr close usage errors exit 2 before any gh call, and the help documents both commands" {
    run --separate-stderr "${SCRIPT}" pr close --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --pr"* ]]
    run --separate-stderr "${SCRIPT}" pr close --repo "${REPO}" --pr 1 --delete-branch
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" pr reopen --pr 1
    [ "${status}" -eq 2 ]
    run "${SCRIPT}" pr close --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf pr close --repo <owner/repo> --pr <n> [--body-file <file|->]"* ]]
    [[ "${output}" == *"Any pull request in the repository can be closed, whoever opened it"*"there is no ownership rule."* ]]
    [[ "${output}" != *"PR_CREATOR_LOGIN"* ]]
    run "${SCRIPT}" help pr reopen
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf pr reopen"* ]]
    [[ "${output}" == *"repository can be reopened, whoever opened it and whoever wrote its commits: there is no ownership"* ]]
    [[ "${output}" != *"anyone"*"else's is refused"* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *"  pr close                 Close a PR without merging it, with an optional comment first (exit 8 refused, 9 not found)"* ]]
    [[ "${output}" == *"  issue reopen             Reopen a closed issue"* ]]
    [[ "${output}" == *"  issue comments           Print an issue's or PR's top-level comments"* ]]
    [ ! -f "${GH_LOG}" ]
}

# --- issue close (#1597) ----------------------------------------------------------

CLOSE_ISSUE=1346
CLOSE_ISSUE_URL="https://github.com/${REPO}/issues/${CLOSE_ISSUE}"

run_issue_close() {
    run --separate-stderr "${SCRIPT}" issue close --repo "${REPO}" --issue "${CLOSE_ISSUE}" "$@"
}

# Writes the issue to close in the state $1 (OPEN by default) with the labels given as the further
# arguments, and no pull request that closes it.
prepare_issue_close() {
    local state="${1:-OPEN}"
    shift || true
    write_issue "${CLOSE_ISSUE}" "fix: something" "${state}" "The body." "$@"
    printf '%s#issuecomment-79\n' "${CLOSE_ISSUE_URL}" > "${GH_FIXTURES}/comment.out"
    printf 'Done in the last release.\n' > "${TEST_TMP}/reason.md"
}

# Adds to the issue to close the pull requests given as owner/repo#number, each referencing it with
# a closing keyword, as gh issue view --json closedByPullRequestsReferences gives them.
write_closing_prs() {
    local fixture ref
    fixture="$(issue_fixture "${CLOSE_ISSUE}").json"
    for ref in "$@"; do
        jq --arg owner "${ref%%/*}" --arg name "$(printf '%s' "${ref#*/}" | cut -d'#' -f1)" --argjson n "${ref##*#}" \
            '.closedByPullRequestsReferences += [{id: "PR_x", number: $n, url: "https://github.com/\($owner)/\($name)/pull/\($n)",
              repository: {id: "R_x", name: $name, owner: {id: "U_x", login: $owner}}}]' "${fixture}" > "${fixture}.new"
        mv "${fixture}.new" "${fixture}"
    done
}

@test "issue close closes an open issue with the reason, prints its URL and the reason, and posts no comment without --body-file" {
    prepare_issue_close
    run_issue_close --reason completed
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${CLOSE_ISSUE_URL} closed (completed)" ]
    [ "$(gh_call_count "issue close ${CLOSE_ISSUE} --repo ${REPO} --reason completed")" -eq 1 ]
    [ "$(gh_call_count "issue comment")" -eq 0 ]

    run_issue_close --reason not-planned
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CLOSE_ISSUE_URL} closed (not-planned)" ]
    [ "$(gh_call_count "issue close ${CLOSE_ISSUE} --repo ${REPO} --reason not planned")" -eq 1 ]
}

@test "issue close posts the checked --body-file as a comment first, then closes" {
    prepare_issue_close
    run_issue_close --reason completed --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/reason.md" "${GH_FIXTURES}/comment-body.txt"
    [ "$(gh_line_of "issue comment ${CLOSE_ISSUE}")" -lt "$(gh_line_of "issue close ${CLOSE_ISSUE}")" ]
}

@test "issue close leaves a closed issue alone, the comment included, and says so" {
    prepare_issue_close CLOSED
    run_issue_close --reason completed --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CLOSE_ISSUE_URL} already closed" ]
    [ "$(gh_call_count "issue close")" -eq 0 ]
    [ "$(gh_call_count "issue comment")" -eq 0 ]
}

@test "issue close refuses (exit 8) an issue that carries On Hold, in any case, writing nothing" {
    prepare_issue_close OPEN AI-Work "on hold"
    run_issue_close --reason not-planned --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: close refused: the issue carries On Hold" ]
    [ "$(gh_call_count "issue close")" -eq 0 ]
    [ "$(gh_call_count "issue comment")" -eq 0 ]
}

@test "issue close refuses (exit 8) when an open pull request references it with a closing keyword, and closes it when every such pull request is closed or merged" {
    prepare_issue_close
    write_closing_prs "credfeto/other-repo#5" "${REPO}#77"
    jq -n '{number: 5, state: "closed", merged: true}' | write_api "repos/credfeto/other-repo/pulls/5"
    jq -n '{number: 77, state: "open"}' | write_api "repos/${REPO}/pulls/77"
    run_issue_close --reason completed --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: close refused: an open pull request references it with a closing keyword and closes it when it merges" ]
    [ "$(gh_call_count "issue close")" -eq 0 ]
    [ "$(gh_call_count "issue comment")" -eq 0 ]

    jq -n '{number: 77, state: "closed"}' | write_api "repos/${REPO}/pulls/77"
    run_issue_close --reason completed
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CLOSE_ISSUE_URL} closed (completed)" ]
}

@test "issue close fails (exit 1) when a closing pull request cannot be read, writing nothing" {
    prepare_issue_close
    write_closing_prs "${REPO}#77"
    fail_api "repos/${REPO}/pulls/77"
    run_issue_close --reason completed
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: could not read the pull request ${REPO}#77, which closes ${REPO}#${CLOSE_ISSUE}"* ]]
    [ "$(gh_call_count "issue close")" -eq 0 ]
}

@test "issue close refuses (exit 8) a body with a leak or a plan-approval keyword before reading or writing anything" {
    prepare_issue_close
    write_leak_body "token ghp_$(printf 'a%.0s' {1..36})"
    run_issue_close --reason completed --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    printf '  Approved\n' > "${TEST_TMP}/approved.md"
    run_issue_close --reason completed --body-file "${TEST_TMP}/approved.md"
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: approval keyword"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue close exits 9 for a number that is no issue or is a pull request's, writing nothing" {
    run_issue_close --reason completed
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${CLOSE_ISSUE} was not found" ]
    jq -n --arg url "https://github.com/${REPO}/pull/${CLOSE_ISSUE}" '{url: $url, state: "OPEN", labels: []}' > "$(issue_fixture "${CLOSE_ISSUE}").json"
    run_issue_close --reason completed
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${CLOSE_ISSUE} is a pull request, not an issue" ]
    [ "$(gh_call_count "issue close")" -eq 0 ]
}

@test "issue close fails (exit 1) naming that the comment was posted when the close itself fails" {
    prepare_issue_close
    echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/state-change.fail"
    run_issue_close --reason completed --body-file "${TEST_TMP}/reason.md"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: could not close ${REPO}#${CLOSE_ISSUE} (the comment was posted): "* ]]
    [ -z "${output}" ]
}

@test "issue close usage errors exit 2 before any gh call: a missing or unknown --reason, duplicate included, a missing --issue, and --comment" {
    local reason
    run --separate-stderr "${SCRIPT}" issue close --repo "${REPO}" --issue 1
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --reason"* ]]
    for reason in duplicate "not planned" COMPLETED ""; do
        run --separate-stderr "${SCRIPT}" issue close --repo "${REPO}" --issue 1 --reason "${reason}"
        [ "${status}" -eq 2 ]
    done
    run --separate-stderr "${SCRIPT}" issue close --repo "${REPO}" --reason completed
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" issue close --repo "${REPO}" --issue 1 --reason completed --comment x
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue close help, from -h and from help, describes the reasons, the refusals and the judgement it cannot make, and calls no gh; help issue and the general help include it" {
    local invocation
    for invocation in "issue close -h" "issue close --help" "help issue close"; do
        # shellcheck disable=SC2086  # each invocation is several words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf issue close --repo <owner/repo> --issue <n> --reason <completed|not-planned> [--body-file <file|->]"* ]]
        [[ "${output}" == *"There is no duplicate"* ]]
        [[ "${output}" == *"the issue carries On Hold"* ]]
        [[ "${output}" == *"That is a judgement this command cannot make"* ]]
    done
    run "${SCRIPT}" help issue
    [[ "${output}" == *"Usage: cfwf issue close "* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  issue close              Close an issue with a reason, with an optional comment first (exit 8 when refused, 9 when not found)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}
