#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- pr list --------------------------------------------------------------------

# Writes $1 open pull requests, numbered from 1, each on a branch of its own.
write_numbered_pr_list() {
    jq -n --argjson count "$1" --arg repo "${REPO}" '[range(1; $count + 1) | {number: ., title: "change \(.)",
        headRefName: "feat/\(.)-change", baseRefName: "main", isDraft: false, isCrossRepository: false,
        author: {login: "someone", is_bot: false}, url: "https://github.com/\($repo)/pull/\(.)"}]' > "${GH_FIXTURES}/pr-list.json"
}

run_pr_list() {
    run --separate-stderr "${SCRIPT}" pr list --repo "${REPO}" "$@"
}

# Prints one line of pr list for the pull request numbered $1: the number, the fields given as the
# rest of the arguments up to the flags, its URL, and the last argument, its title.
pr_list_line() {
    local IFS=$'\t'
    local -a fields=("${@:1:$#-1}" "https://github.com/${REPO}/pull/$1" "${!#}")
    printf '%s\n' "${fields[*]}"
}

# Succeeds when the text $1 has $2 lines, each of exactly eight tab-separated fields, none empty.
has_eight_field_lines() {
    has_field_lines "$1" "$2" 8
}

@test "pr list help gives the usage line, the eight columns, the limit and the exit codes, help pr and the general help point to it, and none calls gh" {
    local flag invocation
    for flag in --help -h; do
        run "${SCRIPT}" pr list "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr list --repo <owner/repo> [--issue <n>] [--head <branch>]"* ]]
        [[ "${output}" == *"  <number>  <head>  <base>  <author>  <draft|ready>  <flags>  <url>  <title>"* ]]
        [[ "${output}" == *"exactly eight tab-separated fields and none is empty"* ]]
        [[ "${output}" == *"At most 1000 pull requests are listed. More than that to list (with --head, more on that"$'\n'"branch) is a runtime failure and nothing is printed, never part of the list."* ]]
        [[ "${output}" == *"Exit codes: 0 listed, an empty list included (nothing is printed); 1 a runtime failure"*"2 a usage error." ]]
        # A fork line is anyone's to open, so the help must say it proves nothing and is never the caller's.
        [[ "${output}" == *"  fork            the head branch is in another repository. Anyone can open such a pull"$'\n'*"access to this repository"*"never the pull request of a branch in this repository"*"no proof of earlier work on an issue"* ]]
        [[ "${output}" == *"matches too, flagged \"fork\": ignore that line when looking for the pull request of a"$'\n'*"branch in this repository."* ]]
    done

    # Options before --help are still checked, and those after it are never looked at.
    run "${SCRIPT}" pr list --repo "${REPO}" --help --bogus
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf pr list "* ]]

    run "${SCRIPT}" help pr list
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf pr list "* ]]

    for invocation in "help pr" "pr -h" "pr --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr checks"*"for pr view, which prints a pull request's state and metadata."$'\n'"Run 'cfwf pr list --help' for pr list, which lists a repository's open pull requests."$'\n'"Run 'cfwf pr diff --help' for pr diff, which prints a pull request's diff, changed files or line counts."$'\n'"Run 'cfwf pr create --help' for pr create, "*$'\n'"Run 'cfwf branch required-checks --help' for branch required-checks, which lists the checks a branch"$'\n'"requires without judging them." ]]
    done

    # pr with no subcommand is a usage error that prints the same usage, so it points to pr list too.
    run --separate-stderr "${SCRIPT}" pr
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"Usage: cfwf pr checks"*$'\n'"Run 'cfwf pr list --help' for pr list, which lists a repository's open pull requests."* ]]

    run "${SCRIPT}" help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"  pr list                  List a repository's open pull requests, one line each"$'\n'"  pr create "*$'\n'"  comment add "* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr list usage errors exit 2 before any gh call, each with the pr list usage" {
    write_pr_list "$(pull_request 5 feat/5-x main someone false false "a title")"
    local -a cases=(
        "--repo ${REPO}"
        "--issue 1 --issue 2"
        "--head feat/a --head feat/b"
        "--issue x"
        "--issue 1x"
        "--issue -1"
        "--issue 0"
        "--issue 000"
        "--issue"
        "--head"
        "--json number"
        "--jq ."
        "--search x"
        "--state all"
        "--limit 5"
        "--author someone"
        "--app dependabot"
        "--base main"
        "--draft"
        "--web"
        "--pr 5"
        "extra"
        "--issue 5 extra"
    )
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_list ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"Usage: cfwf pr list --repo <owner/repo> [--issue <n>] [--head <branch>]"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr list
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --repo"* ]]

    local bad
    for bad in "./x" "x/.." "../.."; do
        run --separate-stderr "${SCRIPT}" pr list --repo "${bad}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == "cfwf: invalid value for --repo: neither the owner nor the repository can be . or .."* ]]
    done

    run_pr_list --repo "${REPO}"
    [[ "${stderr}" == "cfwf: --repo can only be given once"* ]]
    run_pr_list --issue 1 --issue 2
    [[ "${stderr}" == "cfwf: --issue can only be given once"* ]]
    run_pr_list --head feat/a --head feat/b
    [[ "${stderr}" == "cfwf: --head can only be given once"* ]]
    run_pr_list --issue x
    [[ "${stderr}" == "cfwf: invalid value for --issue: it must be a number"$'\n'* ]]
    run_pr_list --issue ""
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --issue: it must be a number"$'\n'* ]]
    for bad in 0 000; do
        run_pr_list --issue "${bad}"
        [[ "${stderr}" == "cfwf: invalid value for --issue: it must be a number above 0"$'\n'* ]]
    done
    run_pr_list --head
    [[ "${stderr}" == "cfwf: --head needs a value"* ]]
    run_pr_list --json number
    [[ "${stderr}" == "cfwf: unknown option (argument 5; its value is not shown)"* && "${stderr%%$'\n'*}" != *json* ]]
    run_pr_list --issue 5 extra
    [[ "${stderr}" == "cfwf: unknown option (argument 7; its value is not shown)"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr list refuses a --head git would not allow, or one holding a control character, without echoing it or calling gh" {
    write_pr_list "$(pull_request 5 feat/5-x main someone false false "a title")"
    local head
    # The last five hold a control character: a tab, a newline and DEL, which git refuses, and two C1
    # controls (U+009B and U+0085), which git allows and only the control-character check refuses.
    for head in "" "-x" "a..b" "a b" "HEAD" "a@{b" "owner:branch" "feat/x.lock" $'feat/a\tb' $'feat/a\nb' $'feat/a\x7fb' \
        $'feat/a\xc2\x9bb' $'feat/a\xc2\x85b'; do
        run_pr_list --head "${head}"
        [ "${status}" -eq 2 ] || { printf 'accepted: %q (%s)\n' "${head}" "${status}" >&2; return 1; }
        [ -z "${output}" ]
        # The first line is the rule alone, so the value is not in it.
        [[ "${stderr}" == "cfwf: invalid value for --head: it must be a branch name git allows, with no control character"$'\n\n'"Usage: cfwf pr list "* ]]
    done
    [ ! -f "${GH_LOG}" ]

    # A character just past C1 (U+00A0), and any other letter, is a branch name like any other.
    run_pr_list --head $'feat/a\xc2\xa0\xc3\xa9'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "pr list prints each open pull request as eight tab-separated fields, sorted by number, from one read of the open ones with no search" {
    write_pr_list "$(pull_request 57 feat/123-add-widget main app/github-actions true false "feat: add the widget")" \
        "$(pull_request 9 fix/9-typo release/1 someone false false "fix: a typo")" \
        "$(pull_request 31 chore/deps main app/dependabot false true "chore: bump a dependency")"
    run_pr_list
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected
    expected="$(pr_list_line 9 fix/9-typo release/1 someone ready - "fix: a typo")"$'\n'
    expected+="$(pr_list_line 31 chore/deps main app/dependabot ready fork "chore: bump a dependency")"$'\n'
    expected+="$(pr_list_line 57 feat/123-add-widget main app/github-actions draft github-actions "feat: add the widget")"
    [ "${output}" = "${expected}" ]
    has_eight_field_lines "${output}" 3

    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "pr list --repo ${REPO} --state open --limit 1001 --json number,title,author,headRefName,baseRefName,isDraft,isCrossRepository,url --jq ")" -eq 1 ]
    [ "$(gh_call_count "--search")" -eq 0 ]
    [ "$(gh_call_count "--head")" -eq 0 ]
}

@test "pr list prints nothing and exits 0 when there is no open pull request, with and without --head" {
    write_pr_list
    run_pr_list
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]

    run_pr_list --head feat/x
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]

    # run drops trailing newlines, so the bytes are counted: an empty list is no output at all, not
    # a blank line, which is not an eight-field row.
    [ "$("${SCRIPT}" pr list --repo "${REPO}" | wc -c)" -eq 0 ]
    [ "$("${SCRIPT}" pr list --repo "${REPO}" --head feat/x | wc -c)" -eq 0 ]

    write_pr_list "$(pull_request 5 feat/5-x main someone false false "a title")"
    run_pr_list --head feat/x --issue 5
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
}

@test "pr list --issue flags a head branch that holds the number with no digit on either side, however the number is written, and nothing without --issue" {
    local -a heads=(feat/12-x fix/12 12-x feat/x-12_y feat/012-x 12 feat/123-x feat/312-x feat/1x2 feat/120 feat/1-2 feat/x)
    local -a pull_requests=()
    local index
    for index in "${!heads[@]}"; do
        pull_requests+=("$(pull_request "$((index + 1))" "${heads[index]}" main someone false false "a title")")
    done
    write_pr_list "${pull_requests[@]}"

    local expected=$'feat/12-x\tissue\nfix/12\tissue\n12-x\tissue\nfeat/x-12_y\tissue\nfeat/012-x\tissue\n12\tissue\n'
    expected+=$'feat/123-x\t-\nfeat/312-x\t-\nfeat/1x2\t-\nfeat/120\t-\nfeat/1-2\t-\nfeat/x\t-'
    local number
    for number in 12 012 00012; do
        run_pr_list --issue "${number}"
        [ "${status}" -eq 0 ]
        [ "$(cut -f 2,6 <<< "${output}")" = "${expected}" ] || { echo "--issue ${number}: ${output}" >&2; return 1; }
        has_eight_field_lines "${output}" "${#heads[@]}"
    done

    # The number goes in the filter without its leading zeros, and nothing else of the caller's does.
    [ "$(gh_call_count '0*12([^0-9]|$)')" -eq 3 ]
    [ "$(gh_call_count '0*012(')" -eq 0 ]

    run_pr_list
    [ "${status}" -eq 0 ]
    [ "$(cut -f 6 <<< "${output}" | sort -u)" = "-" ]

    run_pr_list --issue 2
    [ "$(cut -f 2,6 <<< "${output}" | grep $'\tissue$')" = $'feat/1x2\tissue\nfeat/1-2\tissue' ]
}

@test "pr list flags only the author app/github-actions, and prints an author with no login as -" {
    write_pr_list "$(pull_request 1 feat/a main app/github-actions false false "a title")" \
        "$(pull_request 2 feat/b main app/dependabot false false "a title")" \
        "$(pull_request 3 feat/c main someone false false "a title")" \
        "$(pull_request 4 feat/d main github-actions false false "a title")" \
        "$(pull_request 5 feat/e main app-github-actions false false "a title")" \
        "$(pull_request 6 feat/f main app/github-actions-bot false false "a title")" \
        "$(pull_request 7 feat/g main "" false false "a title")"
    run_pr_list
    [ "${status}" -eq 0 ]
    local expected=$'1\tapp/github-actions\tgithub-actions\n2\tapp/dependabot\t-\n3\tsomeone\t-\n4\tgithub-actions\t-\n'
    expected+=$'5\tapp-github-actions\t-\n6\tapp/github-actions-bot\t-\n7\t-\t-'
    [ "$(cut -f 1,4,6 <<< "${output}")" = "${expected}" ]
    has_eight_field_lines "${output}" 7
}

@test "pr list joins the flags as issue, github-actions, fork in that order, and gives the base and draft or ready as columns" {
    write_pr_list "$(pull_request 1 feat/7-x release/2 app/github-actions true true "all three")" \
        "$(pull_request 2 feat/8-x main someone false false "none")" \
        "$(pull_request 3 feat/7-y main someone true true "two")" \
        "$(pull_request 4 feat/9-x feat/7-x app/github-actions false false "one")"
    run_pr_list --issue 7
    [ "${status}" -eq 0 ]
    local expected
    expected="$(pr_list_line 1 feat/7-x release/2 app/github-actions draft issue,github-actions,fork "all three")"$'\n'
    expected+="$(pr_list_line 2 feat/8-x main someone ready - "none")"$'\n'
    expected+="$(pr_list_line 3 feat/7-y main someone draft issue,fork "two")"$'\n'
    expected+="$(pr_list_line 4 feat/9-x feat/7-x app/github-actions ready github-actions "one")"
    [ "${output}" = "${expected}" ]
}

@test "pr list keeps a title with a tab, a newline, a carriage return or a whole forged row on one line of eight fields" {
    local forged=$'99\tfeat/7-evil\tmain\tapp/github-actions\tdraft\tissue\thttps://github.com/x/y/pull/99\tforged'
    write_pr_list "$(pull_request 1 feat/a main someone false false $'a\ttitle\nwith\r\nbreaks')" \
        "$(pull_request 2 feat/b main someone false false "real"$'\n'"${forged}")" \
        "$(pull_request 3 feat/c main someone false false $'\t\n\x1b')" \
        "$(pull_request 4 feat/d main someone false false "")"
    run_pr_list --issue 7
    [ "${status}" -eq 0 ]
    has_eight_field_lines "${output}" 4
    local expected
    expected="$(pr_list_line 1 feat/a main someone ready - "a title with  breaks")"$'\n'
    expected+="$(pr_list_line 2 feat/b main someone ready - "real ${forged//$'\t'/ }")"$'\n'
    expected+="$(pr_list_line 3 feat/c main someone ready - "   ")"$'\n'
    expected+="$(pr_list_line 4 feat/d main someone ready - "-")"
    [ "${output}" = "${expected}" ]
}

@test "pr list prints every C0, DEL and C1 control in a title or a branch name as a space, and keeps U+00A0, just past C1" {
    # ESC, U+009B (CSI, a one-character escape in C1), U+0085 (NEL) and DEL are controls; U+00A0 is
    # not. This stub runs jq, where gh runs gojq, so the test pins the range, not the engine.
    write_pr_list "$(pull_request 1 $'feat/a\xc2\x9bb' $'ma\xc2\x85in' $'some\x1bone' false false $'a\x1b[1mb\xc2\x9b31mc\xc2\x85d\x7fe\xc2\xa0f')"
    run_pr_list
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(pr_list_line 1 "feat/a b" "ma in" "some one" ready - "a [1mb 31mc d e"$'\xc2\xa0'"f")" ]
    has_eight_field_lines "${output}" 1
}

@test "pr list --head lists only the pull requests whose head branch is exactly that name, a fork's included, and passes it to gh as its own argument" {
    write_pr_list "$(pull_request 1 feat/x main someone false false "the branch")" \
        "$(pull_request 2 feat/x-2 main someone false false "a longer name")" \
        "$(pull_request 3 xfeat/x main someone false false "a longer name still")" \
        "$(pull_request 4 feat/x main stranger false true "a fork's branch of the same name")" \
        "$(pull_request 5 feat/X main someone false false "another case")"
    run_pr_list --head feat/x
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected
    expected="$(pr_list_line 1 feat/x main someone ready - "the branch")"$'\n'
    expected+="$(pr_list_line 4 feat/x main stranger ready fork "a fork's branch of the same name")"
    [ "${output}" = "${expected}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "pr list --repo ${REPO} --state open --limit 1001 --head feat/x --json number,")" -eq 1 ]
    [ "$(gh_call_count "--search")" -eq 0 ]

    write_pr_list "$(pull_request 8 feat/12-x main someone true false "the branch")" \
        "$(pull_request 9 feat/12-y main someone false false "another branch of the issue")"
    run_pr_list --head feat/12-x --issue 12
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(pr_list_line 8 feat/12-x main someone draft issue "the branch")" ]
    run_pr_list --issue 13 --head feat/12-x
    [ "${output}" = "$(pr_list_line 8 feat/12-x main someone draft - "the branch")" ]
}

@test "pr list --head prints nothing and exits 1 when gh answers with a pull request of any other head branch" {
    : > "${GH_FIXTURES}/pr-list.ignore-head"
    write_pr_list "$(pull_request 1 feat/x main someone false false "the branch")" \
        "$(pull_request 2 feat/x-2 main someone false false "another branch")"
    run_pr_list --head feat/x
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${PR_LIST_UNEXPECTED}" ]

    # A head that differs only by a control character prints much like the name asked for, and is
    # still another branch.
    local head
    for head in $'feat/x\xc2\x9b' $'feat/\x1bx' $'feat/x\n'; do
        write_pr_list "$(pull_request 1 "${head}" main someone false false "the branch")"
        run_pr_list --head feat/x
        [ "${status}" -eq 1 ] || { printf 'listed: %q\n' "${head}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "${PR_LIST_UNEXPECTED}" ]
    done

    write_pr_list "$(pull_request 1 feat/x main someone false false "the branch")"
    run_pr_list --head feat/x
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(pr_list_line 1 feat/x main someone ready - "the branch")" ]
}

@test "pr list prints exactly 1000 pull requests, and with more open prints none and exits 1" {
    write_numbered_pr_list 1000
    run_pr_list
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    has_eight_field_lines "${output}" 1000
    [ "${output%%$'\n'*}" = "$(pr_list_line 1 feat/1-change main someone ready - "change 1")" ]
    [ "${output##*$'\n'}" = "$(pr_list_line 1000 feat/1000-change main someone ready - "change 1000")" ]

    write_numbered_pr_list 1001
    run_pr_list
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO} has more than 1000 open pull requests, so none is printed" ]

    write_numbered_pr_list 1500
    run_pr_list --issue 7
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO} has more than 1000 open pull requests, so none is printed" ]

    # The limit is on what the read returns: gh filters on --head before it counts, so a branch is
    # still found in a repository with more open pull requests than the limit.
    run_pr_list --head feat/7-change
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(pr_list_line 7 feat/7-change main someone ready - "change 7")" ]
}

@test "pr list prints nothing and exits 1 when gh's answer is not a count and that many rows, each starting with a number" {
    local row
    row="$(pr_list_line 5 feat/5-x main someone ready - "a title")"
    local -a answers=(
        ""
        "x"
        "one"$'\n'"${row}"
        "-1"$'\n'"${row}"
        "1.0"$'\n'"${row}"
        "99999999999999999999"$'\n'"${row}"
        "${row}"
        "2"$'\n'"${row}"
        "0"$'\n'"${row}"
        "1"$'\n'"${row}"$'\n'"${row}"
        "1"
        "1"$'\n'"x${row}"
        "2"$'\n'"${row}"$'\n'"${row#5}"
        "2"$'\n\n'"${row}"
    )
    local answer
    for answer in "${answers[@]}"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/pr-list.out"
        run_pr_list
        [ "${status}" -eq 1 ] || { printf 'accepted: %q (%s)\n' "${answer}" "${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "${PR_LIST_UNEXPECTED}" ]
    done

    printf '1\n%s\n' "${row}" > "${GH_FIXTURES}/pr-list.out"
    run_pr_list
    [ "${status}" -eq 0 ]
    [ "${output}" = "${row}" ]

    # A number that is not one, as the filter itself prints it.
    rm -f "${GH_FIXTURES}/pr-list.out"
    write_pr_list "$(pull_request 5 feat/5-x main someone false false "a title")" "$(pull_request '"6x"' feat/6-x main someone false false "a title")"
    run_pr_list
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${PR_LIST_UNEXPECTED}" ]
}

@test "pr list treats a failed read, or a repository that is not found, as a runtime failure (exit 1), never as an empty list" {
    write_pr_list
    printf '%s\n' "gh: Bad Gateway (HTTP 502)" "a second line" > "${GH_FIXTURES}/pr-list.fail"
    run_pr_list
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the open pull requests of ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    printf '%s\n' "GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" > "${GH_FIXTURES}/pr-list.fail"
    run_pr_list --head feat/x
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the open pull requests of ${REPO}: GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" ]
}

@test "pr list fails (exit 1) when gh is not installed, after the options are checked" {
    mkdir -p "${TEST_TMP}/empty-path"
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr list --repo "${REPO}" --issue 12
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]

    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr list --repo "${REPO}" --issue 0
    [ "${status}" -eq 2 ]

    # --head is judged by git, so a host without it is a runtime failure, not a usage error.
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr list --repo "${REPO}" --head feat/x
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: git is not installed"* ]]
}

# --- pr view --------------------------------------------------------------------
# Writes PR 42 as gh pr view --json answers it: open, ready, with no review decision, no labels, no
# assignees, one commit and one changed file. $1, when given, is a jq filter that changes it. It
# holds every field cfwf can ask for; the stub hands over only those a call names in --json.
write_pull_request() {
    jq -n --arg url "${PR_URL}" --arg sha "${HEAD_SHA}" --arg created "${CREATED_AT}" '{
        state: "OPEN", isDraft: false, title: "feat: add a thing", url: $url,
        baseRefName: "main", headRefName: "feat/thing", headRefOid: $sha,
        autoMergeRequest: null, reviewDecision: "", mergeStateStatus: "BLOCKED", mergeable: "MERGEABLE",
        createdAt: $created, mergedAt: null, mergeCommit: null,
        labels: [], assignees: [], author: {login: "prpixie", is_bot: false},
        commits: [{oid: "c1", authors: [{login: "credfeto", name: "Mark"}]}],
        files: [{path: "README.md", additions: 1, deletions: 0}], changedFiles: 1,
        body: "Summary\n"} | '"${1:-.}" > "${GH_FIXTURES}/pr-view.json"
}

# Makes the pull request read fail with the error text $1.
fail_pull_request() {
    printf '%s\n' "$1" > "${GH_FIXTURES}/pr-view.fail"
}

run_pr_view() {
    run --separate-stderr "${SCRIPT}" pr view --repo "${REPO}" --pr 42 "$@"
}

# Prints the default output of the pull request write_pull_request writes with no filter, with the
# values given as name=value in place of its own.
default_view() {
    local -A values=(
        [state]=OPEN [draft]=no [title]="feat: add a thing" [url]="${PR_URL}" [base]=main [head]=feat/thing
        [head-sha]="${HEAD_SHA}" [auto-merge]=off [review-decision]="" [merge-state]=BLOCKED
        [mergeable]=MERGEABLE [created-at]="${CREATED_AT}" [merged-at]="" [merge-commit]="" [labels]=""
        [assignees]="" [author]=prpixie [commit-authors]=credfeto
    )
    local change name
    for change in "$@"; do
        values["${change%%=*}"]="${change#*=}"
    done
    for name in "${VIEW_LINE_FIELDS[@]}"; do
        printf '%s\t%s\n' "${name}" "${values["${name}"]}"
    done
}

# Succeeds when pr view --field body, with any further arguments, exits 0 and prints exactly the
# bytes $1. The script is not run through bats' run, which drops the trailing newlines.
body_prints() {
    local expected="$1"
    shift
    printf '%s' "${expected}" > "${TEST_TMP}/expected-body"
    "${SCRIPT}" pr view --repo "${REPO}" --pr 42 --field body "$@" > "${TEST_TMP}/printed-body" || return 1
    cmp "${TEST_TMP}/expected-body" "${TEST_TMP}/printed-body"
}

# Succeeds when gh was called exactly once, as pr view of PR 42 asking for exactly the fields $1.
read_once_asking_for() {
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ] && [ "$(gh_call_count "pr view 42 --repo ${REPO} --json $1 --jq ")" -eq 1 ]
}

@test "pr view help, from help pr view, pr view --help and pr view -h, lists every field and exit code and calls no gh" {
    local flag name
    for flag in "pr view --help" "pr view -h" "help pr view"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${flag}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr view --repo <owner/repo> --pr <n> [--field <name> ...]"* ]]
        [[ "${output}" != *"cfwf pr checks"* ]]
        for name in "${VIEW_LINE_FIELDS[@]}" files body; do
            grep -qE "^  ${name} +[A-Za-z]" <<< "${output}" || { echo "not listed: ${name}" >&2; return 1; }
        done
        [[ "${output}" == *"Exit codes: 0 printed; 9 the pull request does not exist (the number of an issue included); 1 a"* ]]
        [[ "${output}" == *"2 a usage error."* ]]
        [[ "${output}" == *"--json, --jq and --template are not options"* ]]
        [[ "${output}" == *"only when asked for alone"* ]]
    done

    # Help comes before any other option is looked at.
    run "${SCRIPT}" pr view --help --field nonsense
    [ "${status}" -eq 0 ]

    for flag in "help pr" "pr -h" "pr --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${flag}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr checks"*"Run 'cfwf pr view --help' for pr view"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr view prints every field but files and body for an open pull request, in the fixed order, empty where there is no value" {
    write_pull_request
    run_pr_view
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(default_view)" ]
    [ -z "${stderr}" ]
    [ "$(grep -c . <<< "${output}")" -eq 18 ]
    # Each empty value keeps its tab, the last line's included.
    [ "$(grep -c $'^[a-z-]*\t' <<< "${output}")" -eq 18 ]
    [ "$(grep -cx $'review-decision\t' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx $'merged-at\t' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx $'merge-commit\t' <<< "${output}")" -eq 1 ]
}

@test "pr view prints a draft pull request" {
    write_pull_request '.isDraft = true | .mergeStateStatus = "DRAFT" | .reviewDecision = "REVIEW_REQUIRED"'
    run_pr_view
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(default_view draft=yes merge-state=DRAFT review-decision=REVIEW_REQUIRED)" ]
}

@test "pr view prints a merged pull request, with when it merged and the merge commit's SHA" {
    write_pull_request '.state = "MERGED" | .mergedAt = "'"${MERGED_AT}"'" | .mergeCommit = {oid: "'"${MERGE_SHA}"'"}
        | .reviewDecision = "APPROVED" | .mergeStateStatus = "UNKNOWN" | .mergeable = "UNKNOWN"
        | .autoMergeRequest = {enabledAt: "2026-10-02T09:00:00Z", mergeMethod: "MERGE"}'
    run_pr_view
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(default_view state=MERGED merged-at="${MERGED_AT}" merge-commit="${MERGE_SHA}" \
        review-decision=APPROVED merge-state=UNKNOWN mergeable=UNKNOWN auto-merge=on)" ]
}

@test "pr view prints a closed pull request, which has no merge time and no merge commit" {
    write_pull_request '.state = "CLOSED" | .mergeStateStatus = "DIRTY" | .mergeable = "CONFLICTING" | .reviewDecision = "CHANGES_REQUESTED"'
    run_pr_view
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(default_view state=CLOSED merge-state=DIRTY mergeable=CONFLICTING review-decision=CHANGES_REQUESTED)" ]
    [ "$(grep -cx $'merged-at\t' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx $'merge-commit\t' <<< "${output}")" -eq 1 ]
}

@test "pr view --field prints each field alone, asking gh for that field only" {
    local -a cases=(
        "state|state|MERGED"
        "draft|isDraft|no"
        "title|title|feat: add a thing"
        "url|url|${PR_URL}"
        "base|baseRefName|main"
        "head|headRefName|feat/thing"
        "head-sha|headRefOid|${HEAD_SHA}"
        "auto-merge|autoMergeRequest|on"
        "review-decision|reviewDecision|APPROVED"
        "merge-state|mergeStateStatus|BLOCKED"
        "mergeable|mergeable|MERGEABLE"
        "created-at|createdAt|${CREATED_AT}"
        "merged-at|mergedAt|${MERGED_AT}"
        "merge-commit|mergeCommit|${MERGE_SHA}"
        "labels|labels|AI-Work,High"
        "assignees|assignees|credfeto,prpixie"
        "author|author|prpixie"
        "commit-authors|commits|credfeto"
    )
    local case name rest
    write_pull_request '.state = "MERGED" | .mergedAt = "'"${MERGED_AT}"'" | .mergeCommit = {oid: "'"${MERGE_SHA}"'"}
        | .reviewDecision = "APPROVED" | .autoMergeRequest = {mergeMethod: "MERGE"}
        | .labels = [{name: "AI-Work"}, {name: "High"}] | .assignees = [{login: "credfeto"}, {login: "prpixie"}]'
    for case in "${cases[@]}"; do
        name="${case%%|*}"
        rest="${case#*|}"
        rm -f "${GH_LOG}"
        run_pr_view --field "${name}"
        [ "${status}" -eq 0 ] || { echo "${name}: ${status} ${stderr}" >&2; return 1; }
        [ "${output}" = "${name}"$'\t'"${rest#*|}" ] || { echo "${name}: ${output}" >&2; return 1; }
        read_once_asking_for "${rest%%|*}" || { echo "${name}: $(cat "${GH_LOG}")" >&2; return 1; }
    done
}

@test "pr view --field prints several fields in the fixed order, not the order given, and a repeated one once" {
    write_pull_request
    run_pr_view --field mergeable --field head-sha --field state --field draft
    [ "${status}" -eq 0 ]
    [ "${output}" = "state"$'\t'"OPEN"$'\n'"draft"$'\t'"no"$'\n'"head-sha"$'\t'"${HEAD_SHA}"$'\n'"mergeable"$'\t'"MERGEABLE" ]
    read_once_asking_for "state,isDraft,headRefOid,mergeable"

    rm -f "${GH_LOG}"
    run_pr_view --field state --field title --field state --field state
    [ "${status}" -eq 0 ]
    [ "${output}" = "state"$'\t'"OPEN"$'\n'"title"$'\t'"feat: add a thing" ]
    read_once_asking_for "state,title"

    # The last line keeps its tab when its value is empty.
    run_pr_view --field merge-commit --field state
    [ "${status}" -eq 0 ]
    [ "${output}" = "state"$'\t'"OPEN"$'\n'"merge-commit"$'\t' ]
}

@test "pr view asks gh only for the fields the request needs: no body or files by default, and commits only for commit-authors" {
    write_pull_request
    run_pr_view
    [ "${status}" -eq 0 ]
    read_once_asking_for "${DEFAULT_JSON_FIELDS}"
    [[ ",${DEFAULT_JSON_FIELDS}," != *",body,"* && ",${DEFAULT_JSON_FIELDS}," != *",files,"* ]]

    rm -f "${GH_LOG}"
    run_pr_view --field state
    [ "${status}" -eq 0 ]
    read_once_asking_for "state"

    rm -f "${GH_LOG}"
    run_pr_view --field body
    [ "${status}" -eq 0 ]
    read_once_asking_for "body"

    rm -f "${GH_LOG}"
    run_pr_view --field files
    [ "${status}" -eq 0 ]
    read_once_asking_for "files,changedFiles"

    # No other gh command, and no pass-through of the caller's own filter.
    [ "$(gh_call_count " api ")" -eq 0 ]
}

@test "pr view prints auto-merge as on or off and draft as yes or no" {
    write_pull_request
    run_pr_view --field auto-merge --field draft
    [ "${output}" = "draft"$'\t'"no"$'\n'"auto-merge"$'\t'"off" ]

    write_pull_request '.isDraft = true | .autoMergeRequest = {enabledAt: "2026-10-02T09:00:00Z", enabledBy: {login: "credfeto"}, mergeMethod: "SQUASH"}'
    run_pr_view --field auto-merge --field draft
    [ "${status}" -eq 0 ]
    [ "${output}" = "draft"$'\t'"yes"$'\n'"auto-merge"$'\t'"on" ]
}

@test "pr view comma-joins labels and assignees, and prints an empty value when there are none" {
    write_pull_request
    run_pr_view --field labels --field assignees
    [ "${status}" -eq 0 ]
    [ "${output}" = "labels"$'\t'$'\n'"assignees"$'\t' ]

    write_pull_request '.labels = [{name: "AI-Work", color: "ffa500"}, {name: "Tech Debt"}, {name: "C#"}]
        | .assignees = [{login: "credfeto", name: "Mark"}, {login: "prpixie"}, {login: "dependabot[bot]"}]'
    run_pr_view --field labels --field assignees
    [ "${status}" -eq 0 ]
    [ "${output}" = "labels"$'\t'"AI-Work,Tech Debt,C#"$'\n'"assignees"$'\t'"credfeto,prpixie,dependabot[bot]" ]

    write_pull_request '.labels = [{name: "Low"}] | .assignees = [{login: "credfeto"}]'
    run_pr_view --field labels --field assignees
    [ "${output}" = "labels"$'\t'"Low"$'\n'"assignees"$'\t'"credfeto" ]
}

@test "pr view prints the distinct commit authors in first-seen order, across several authors of one commit, skipping one with no login" {
    write_pull_request '.commits = [
        {authors: [{login: "zoe"}]},
        {authors: [{login: "credfeto"}, {login: "", name: "No Account"}, {login: "zoe"}]},
        {authors: [{login: null, name: "Also None"}, {login: "amy"}]},
        {authors: []},
        {authors: [{login: "credfeto"}]},
        {authors: [{login: "dependabot[bot]"}, {login: "amy"}]}]'
    run_pr_view --field commit-authors
    [ "${status}" -eq 0 ]
    [ "${output}" = "commit-authors"$'\t'"zoe,credfeto,amy,dependabot[bot]" ]

    write_pull_request '.commits = [{authors: [{login: ""}]}]'
    run_pr_view --field commit-authors
    [ "${status}" -eq 0 ]
    [ "${output}" = "commit-authors"$'\t' ]

    write_pull_request '.commits = []'
    run_pr_view --field commit-authors
    [ "${status}" -eq 0 ]
    [ "${output}" = "commit-authors"$'\t' ]
}

@test "pr view --field body prints the body unchanged, byte for byte, with its tabs, blank lines, carriage returns and trailing newlines" {
    write_pull_request '.body = "## Summary\n\n\tindented\twith tabs\r\n\n\n- item\u001b[1m\n   \nlast line\n\n\n"'
    body_prints $'## Summary\n\n\tindented\twith tabs\r\n\n\n- item\x1b[1m\n   \nlast line\n\n\n'
    read_once_asking_for "body"

    # No newline is added to a body that ends without one, and a repeated --field body is still alone.
    write_pull_request '.body = "no newline at the end"'
    body_prints "no newline at the end" --field body

    # A body that ends in the character cfwf marks its end with loses nothing.
    write_pull_request '.body = "ends in the mark\n\u001f"'
    body_prints $'ends in the mark\n\x1f'
}

@test "pr view --field body prints nothing for an empty body or none" {
    local body
    for body in '""' null; do
        write_pull_request ".body = ${body}"
        body_prints ""
    done
}

@test "pr view --field files prints one changed path a line, and nothing when there are none" {
    write_pull_request '.files = [{path: "README.md"}, {path: "docs/a file with spaces.md"}, {path: "src/Thing.cs"}] | .changedFiles = 3'
    run_pr_view --field files
    [ "${status}" -eq 0 ]
    [ "${output}" = "README.md"$'\n'"docs/a file with spaces.md"$'\n'"src/Thing.cs" ]
    [ -z "${stderr}" ]

    write_pull_request '.files = [{path: "README.md"}] | .changedFiles = 1'
    run_pr_view --field files --field files
    [ "${status}" -eq 0 ]
    [ "${output}" = "README.md" ]

    write_pull_request '.files = [] | .changedFiles = 0'
    "${SCRIPT}" pr view --repo "${REPO}" --pr 42 --field files > "${TEST_TMP}/printed-files"
    [ ! -s "${TEST_TMP}/printed-files" ]

    # A path holding a newline or a tab is still one line.
    write_pull_request '.files = [{path: "odd\nname\there"}, {path: "b"}] | .changedFiles = 2'
    run_pr_view --field files
    [ "${status}" -eq 0 ]
    [ "${output}" = "odd name here"$'\n'"b" ]
}

@test "pr view --field files refuses a list gh cut short (exit 1), never printing part of it as the whole" {
    write_pull_request '.files = [{path: "a"}, {path: "b"}] | .changedFiles = 209'
    run_pr_view --field files
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#42 changes 209 files and gh listed only the first 2, so none is printed" ]

    write_pull_request '.files = [] | .changedFiles = 1'
    run_pr_view --field files
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]

    # Without the count there is nothing to check the list against.
    write_pull_request 'del(.changedFiles)'
    run_pr_view --field files
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected number of changed files for ${REPO}#42" ]
}

@test "pr view refuses body or files together with another field (exit 2) before any gh call" {
    local -a cases=(
        "--field body --field state"
        "--field state --field body"
        "--field files --field state"
        "--field title --field files"
        "--field body --field files"
        "--field files --field body --field body"
    )
    local args
    write_pull_request
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_view ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr%%$'\n'*}" == "cfwf: --field "*" can only be asked for alone: it is not printed as a key and value line" ]]
        [[ "${stderr}" == *"Usage: cfwf pr view"* ]]
    done
    run_pr_view --field body --field state
    [[ "${stderr%%$'\n'*}" == "cfwf: --field body can only be asked for alone"* ]]
    run_pr_view --field state --field files
    [[ "${stderr%%$'\n'*}" == "cfwf: --field files can only be asked for alone"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr view usage errors exit 2 with the pr view usage, before any gh call" {
    local -a cases=(
        "--repo ${REPO}"
        "--repo ${REPO} --pr 42 --pr 43"
        "--repo ${REPO} --repo ${REPO} --pr 42"
        "--repo ${REPO} --pr x42"
        "--repo ${REPO} --pr 42x"
        "--repo ${REPO} --pr -1"
        "--repo ${REPO} --pr 4.2"
        "--repo ${REPO} --pr 0"
        "--repo ${REPO} --pr 000"
        "--repo ${REPO} --pr"
        "--repo not-a-repo --pr 42"
        "--repo ${REPO} --pr 42 --field"
        "--repo ${REPO} --pr 42 --field nonsense"
        "--repo ${REPO} --pr 42 --field State"
        "--repo ${REPO} --pr 42 --field isDraft"
        "--repo ${REPO} --pr 42 --field headRefOid"
        "--repo ${REPO} --pr 42 --field state,title"
        "--repo ${REPO} --pr 42 --field number"
        "--repo ${REPO} --pr 42 --json state"
        "--repo ${REPO} --pr 42 --jq .state"
        "--repo ${REPO} --pr 42 --template x"
        "--repo ${REPO} --pr 42 --web"
        "--repo ${REPO} --pr 42 --comments"
        "--repo ${REPO} --pr 42 --issue 42"
        "--repo ${REPO} --pr 42 --sha ${HEAD_SHA}"
        "--repo ${REPO} --pr 42 --all"
        "--repo ${REPO} --pr 42 state"
        "--repo ${REPO} 42"
    )
    local args
    write_pull_request
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr view ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"Usage: cfwf pr view --repo <owner/repo> --pr <n> [--field <name> ...]"* ]]
        [[ "${stderr}" != *"cfwf pr checks"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr view --pr 42
    [[ "${stderr}" == "cfwf: missing required option --repo"* ]]
    run --separate-stderr "${SCRIPT}" pr view --repo "${REPO}"
    [[ "${stderr}" == "cfwf: missing required option --pr"* ]]
    run_pr_view --pr 43
    [[ "${stderr}" == "cfwf: --pr can only be given once"* ]]
    run_pr_view --repo "${REPO}"
    [[ "${stderr}" == "cfwf: --repo can only be given once"* ]]
    run --separate-stderr "${SCRIPT}" pr view --repo "${REPO}" --pr x42
    [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --pr: it must be a number" ]]
    # gh would look for a branch named 0 rather than a pull request numbered 0.
    run --separate-stderr "${SCRIPT}" pr view --repo "${REPO}" --pr 0
    [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --pr: it must be a number above 0" ]]
    run_pr_view --field
    [[ "${stderr}" == "cfwf: --field needs a value"* ]]

    # An unknown field is named by the rule it broke, never by its value, and so is an unknown option.
    run_pr_view --field nonsense
    [[ "${stderr%%$'\n'*}" == "cfwf: unknown --field: it must be one of the fields listed below" ]]
    run_pr_view --json nonsense
    [[ "${stderr%%$'\n'*}" == "cfwf: unknown option (argument 7; its value is not shown)" ]]

    [ ! -f "${GH_LOG}" ]
}

@test "pr without a subcommand names every subcommand, and pr checks still runs as before" {
    run --separate-stderr "${SCRIPT}" pr
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: pr needs a subcommand (checks, checks-wait, view, list, comments, reply, create, ready-at, status, auto-merge-at, diff, edit, hand-off, finalise-dependency, take-back, close, reopen, block, unblock, search, post-merge-runs, sync-labels, review-comment, comment)"* ]]
    [[ "${stderr}" == *"Usage: cfwf pr checks"*"Run 'cfwf pr view --help' for pr view"* ]]

    run --separate-stderr "${SCRIPT}" pr frobnicate
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown pr subcommand (argument 2; its value is not shown)"* ]]
    [ ! -f "${GH_LOG}" ]

    prepare_pr_checks
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]]
}

@test "pr view exits 9 for a pull request that does not exist, and for the number of an issue, which gh answers the same way" {
    fail_pull_request "GraphQL: Could not resolve to a PullRequest with the number of 42. (repository.pullRequest)"
    run_pr_view
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]

    run_pr_view --field body
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    run_pr_view --field files
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
}

@test "pr view reports a failing gh as a runtime failure (exit 1), a repository that is not there included, and prints nothing" {
    write_pull_request
    fail_pull_request "HTTP 502: Bad Gateway (https://api.github.com/graphql)"
    run_pr_view
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#42: HTTP 502: Bad Gateway (https://api.github.com/graphql)" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]

    local field
    for field in body files state; do
        run_pr_view --field "${field}"
        [ "${status}" -eq 1 ] || { echo "${field}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
    done

    fail_pull_request "GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)"
    run_pr_view
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#42: GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" ]

    # Only the first line of gh's error is quoted, with no terminal escape.
    fail_pull_request $'first \x1b[31mline\nsecond line'
    run_pr_view
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#42: first [31mline" ]
}

@test "pr view fails (exit 1) when gh is not installed, after the options are checked" {
    write_pull_request
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr view --repo "${REPO}" --pr 42
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]

    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr view --repo "${REPO}" --pr 42 --field nonsense
    [ "${status}" -eq 2 ]
}

@test "pr view prints a tab, a newline or a carriage return in a title, label, branch or login as a space, so it never adds or alters a line" {
    write_pull_request '.title = "feat: a\ttitle\nstate\tMERGED\r\nauto-merge\ton"
        | .labels = [{name: "one\ntwo"}, {name: "three\tfour"}, {name: "five\rsix"}]
        | .headRefName = "feat/x\nmerged-at\t2026-01-01T00:00:00Z" | .baseRefName = "main\tline"
        | .assignees = [{login: "a\nb"}] | .author = {login: "bot\tname\r"}
        | .commits = [{authors: [{login: "c\nd"}]}]'
    run_pr_view
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(default_view "title=feat: a title state MERGED  auto-merge on" "labels=one two,three four,five six" \
        "head=feat/x merged-at 2026-01-01T00:00:00Z" "base=main line" "assignees=a b" "author=bot name " "commit-authors=c d")" ]
    [ "$(grep -c '' <<< "${output}")" -eq 18 ]
    [ "$(grep -cx $'state\tOPEN' <<< "${output}")" -eq 1 ]
    [ "$(grep -c '^state' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx $'merged-at\t' <<< "${output}")" -eq 1 ]
    [ "$(grep -c '^merged-at' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx $'auto-merge\toff' <<< "${output}")" -eq 1 ]
    # Every line has exactly one tab: the one after its name.
    [ "$(tr -cd '\t' <<< "${output}" | wc -c)" -eq 18 ]
    [[ "${output}" != *$'\r'* ]]
}

@test "pr view prints every C0, DEL and C1 control in a value as a space, and keeps U+00A0, just past C1" {
    # ESC, U+009B (CSI, a one-character escape in C1), U+0085 (NEL) and DEL are controls; U+00A0 is
    # not. The stub runs jq and gh runs gojq, so this pins the range, not the engine.
    write_pull_request '.title = "a\u001b[1mb\u009b31mc\u0085d\u007fe" + ([160] | implode) + "f"'
    run_pr_view --field title
    [ "${status}" -eq 0 ]
    [ "${output}" = "title"$'\t'"a [1mb 31mc d e"$'\xc2\xa0'"f" ]
}

@test "closing-issue-labels still reads its pull request through the stub's pr view route" {
    # The whole pull request, not write_pr_view's closing references alone: the stub must hand the
    # filter that one field out of a fixture holding every other.
    write_pull_request '.closingIssuesReferences = [{repository: {owner: {login: "credfeto"}, name: "credfeto-orchestrator"}, number: 10}]'
    jq -n '{labels: [{name: "Medium"}]}' > "${GH_FIXTURES}/issue-view-10.json"
    run "${SCRIPT}" closing-issue-labels --repo "${REPO}" --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "Medium" ]
}

# --- pr diff --------------------------------------------------------------------

DIFF_USAGE="Usage: cfwf pr diff --repo <owner/repo> --pr <n> [--name-only | --stat]"
DIFF_CALL="pr diff 42 --repo ${REPO} --color never"
PULL_ENDPOINT="repos/${REPO}/pulls/42"
FILES_ENDPOINT="repos/${REPO}/pulls/42/files"
DIFF_BYTE_LIMIT=1048576
# A diff with a tab, a carriage return and a file with no newline at its end, all of which are content.
SAMPLE_DIFF=$'diff --git a/a.txt b/a.txt\nindex 1111111..2222222 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n-old\tline\n+new\tline\r\n context\n\\ No newline at end of file\n'

# Writes the diff gh pr diff prints for PR 42: $1, byte for byte.
write_diff() {
    printf '%s' "$1" > "${GH_FIXTURES}/pr-diff.out"
}

# Writes a diff of one line, the character $2 (a by default) repeated $1 times, and its newline.
# The line is built with a pipeline, not run_of: at 1 MiB a bash pattern substitution takes minutes.
write_sized_diff() {
    local character="${2:-a}"
    { head -c "$1" /dev/zero | tr '\0' a | sed "s/a/${character}/g"; printf '\n'; } > "${GH_FIXTURES}/pr-diff.out"
}

# Makes gh pr diff fail with the error text $1.
fail_diff() {
    printf '%s\n' "$1" > "${GH_FIXTURES}/pr-diff.fail"
}

# Writes PR 42 as the pulls endpoint gives it, changing $1 files, with fields pr diff never asks for.
write_pr_changed_files() {
    jq -n --argjson changed "$1" '{number: 42, state: "open", title: "a title", changed_files: $changed, additions: 10, deletions: 2}' \
        | write_api "${PULL_ENDPOINT}"
}

# One file of a pull request as the files endpoint gives it: its status $1, path $2, and additions
# $3 and deletions $4, each as JSON, so a test can give a value that is not a number.
diff_file() {
    jq -n -c --arg status "$1" --arg path "$2" --argjson additions "$3" --argjson deletions "$4" \
        '{sha: "abc", filename: $path, status: $status, additions: $additions, deletions: $deletions, changes: 0, patch: "@@ -1 +1 @@"}'
}

# One page of the files list: each argument a file (diff_file), in the order given.
files_page() {
    printf '%s\n' "$@" | jq -c -s '.'
}

# Writes the files of PR 42 as one page, each argument a file, none for an empty list.
write_files() {
    files_page "$@" | write_api "${FILES_ENDPOINT}"
}

# Writes the files of PR 42 as several pages, which the gh stub hands to the jq program one at a
# time, as gh --paginate does: each argument a page (files_page).
write_files_pages() {
    printf '%s\n' "$@" | jq -s '.' > "$(api_fixture "${FILES_ENDPOINT}").pages"
}

# Prints a page of the files $1 to $2, each modified, named file-<n>.txt, with n additions and 1
# deletion.
numbered_files_page() {
    jq -n -c --argjson from "$1" --argjson to "$2" \
        '[range($from; $to + 1) | {filename: "file-\(.).txt", status: "modified", additions: ., deletions: 1}]'
}

run_pr_diff() {
    run --separate-stderr "${SCRIPT}" pr diff --repo "${REPO}" --pr 42 "$@"
}

# Succeeds when pr diff, with any further arguments, exits 0 and prints exactly the bytes in the
# fixture. The script is not run through bats' run, which drops the trailing newlines.
diff_prints_fixture() {
    "${SCRIPT}" pr diff --repo "${REPO}" "$@" > "${TEST_TMP}/printed-diff" || return 1
    cmp "${GH_FIXTURES}/pr-diff.out" "${TEST_TMP}/printed-diff"
}

# Runs pr diff with the arguments after $1 and succeeds when it is a usage error (exit 2) with
# nothing on stdout, the message $1 on the first line of stderr and the pr diff usage after it. It
# runs the script itself rather than through bats' run, so it never reads run's globals; stderr is
# left in TEST_TMP/diff-usage-error.
diff_usage_error() {
    local expected="$1" code=0 printed errors
    shift
    printed=$("${SCRIPT}" pr diff "$@" 2> "${TEST_TMP}/diff-usage-error") || code=$?
    errors=$(< "${TEST_TMP}/diff-usage-error")
    [ "${code}" -eq 2 ] || { echo "exit ${code} for: $*" >&2; return 1; }
    [ -z "${printed}" ]
    [ "${errors%%$'\n'*}" = "cfwf: ${expected}" ] || { echo "for $*: ${errors%%$'\n'*}" >&2; return 1; }
    [[ "${errors}" == *$'\n'"${DIFF_USAGE}"$'\n'* ]]
}

@test "pr diff help, from help pr diff, pr diff --help and pr diff -h, gives the usage, the formats, the status letters, both caps, the local alternative and the exit codes, and calls no gh" {
    local invocation
    for invocation in "pr diff --help" "pr diff -h" "help pr diff"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [[ "${output}" == "${DIFF_USAGE}"$'\n'* ]]
        [[ "${output}" != *"cfwf pr checks"* ]]
        [[ "${output}" == *"  --name-only  <letter><TAB><path>, one line a file, in the order of the diff"* ]]
        [[ "${output}" == *"  --stat       <path><TAB><additions><TAB><deletions>, one line a file, in the order of the diff"* ]]
        [[ "${output}" == *$'\n'"  A  added"$'\n'"  M  modified, or changed in another way (such as its mode only)"$'\n'"  D  removed"$'\n'"  R  renamed"$'\n'"  C  copied"$'\n'"  -  unchanged"$'\n'* ]]
        [[ "${output}" == *"--name-only and --stat are mutually exclusive. --json, --jq, --patch, --exclude, --color, --web and"$'\n'"a path are not options"* ]]
        [[ "${output}" == *"A diff of more than ${DIFF_BYTE_LIMIT} bytes (1 MiB) is refused (exit 1) and none of it is printed"* ]]
        [[ "${output}" == *"GitHub lists at most 3000 files"* ]]
        [[ "${output}" == *"terminal escape sequences"$'\n'"               neutralised"* ]]
        [[ "${output}" == *"When the branch is checked out locally, git -C <repo> diff origin/<base>...HEAD (or --name-status,"$'\n'"--numstat) is better: it needs no network and has no cap."* ]]
        [[ "${output}" == *"Exit codes: 0 printed (an empty diff or file list prints nothing); 9 the pull request does not"$'\n'"exist (the number of an issue included); 1 a runtime failure"*"2 a"$'\n'"usage error." ]]
    done

    # Help comes before any other option is looked at.
    run "${SCRIPT}" pr diff --help --json x
    [ "${status}" -eq 0 ]
    [[ "${output}" == "${DIFF_USAGE}"* ]]

    for invocation in "help pr" "pr -h" "pr --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr checks"*"Run 'cfwf pr diff --help' for pr diff, which prints a pull request's diff, changed files or line counts."* ]]
    done

    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  pr diff                  Print a PR's diff, its changed files or a per-file line count (exit 9 when not found)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr diff usage errors exit 2 with the pr diff usage on stderr and nothing on stdout, never echoing a value, before any gh call" {
    diff_usage_error "missing required option --repo" --pr 42
    diff_usage_error "missing required option --pr" --repo "${REPO}"
    diff_usage_error "missing required option --repo" --name-only
    diff_usage_error "--repo needs a value" --pr 42 --repo
    diff_usage_error "--pr needs a value" --repo "${REPO}" --pr

    local value
    for value in 0 000; do
        diff_usage_error "invalid value for --pr: it must be a number above 0" --repo "${REPO}" --pr "${value}"
    done
    for value in abc -1 4x2 ""; do
        diff_usage_error "invalid value for --pr: it must be a number" --repo "${REPO}" --pr "${value}"
    done
    diff_usage_error "invalid value for --repo: it must be <owner>/<repo>" --repo "credfeto" --pr 42

    diff_usage_error "--pr can only be given once" --repo "${REPO}" --pr 42 --pr 42
    diff_usage_error "--repo can only be given once" --repo "${REPO}" --repo "${REPO}" --pr 42
    diff_usage_error "--name-only can only be given once" --repo "${REPO}" --pr 42 --name-only --name-only
    diff_usage_error "--stat can only be given once" --repo "${REPO}" --pr 42 --stat --stat
    diff_usage_error "--name-only and --stat are mutually exclusive" --repo "${REPO}" --pr 42 --name-only --stat
    diff_usage_error "--name-only and --stat are mutually exclusive" --repo "${REPO}" --pr 42 --stat --name-only

    # No passthrough to gh, no path filter and no other output format: each is an unknown option,
    # named by its position.
    local flag
    for flag in --json --jq --patch --exclude -e --color --web --allow-escape-sequences --name-status --field README.md 42 --; do
        diff_usage_error "unknown option (argument 7; its value is not shown)" --repo "${REPO}" --pr 42 "${flag}" value
    done

    # A stray value that could hold a token is never echoed.
    local token
    token="ghp_$(run_of a 36)"
    diff_usage_error "unknown option (argument 7; its value is not shown)" --repo "${REPO}" --pr 42 "${token}"
    [[ "$(< "${TEST_TMP}/diff-usage-error")" != *"${token}"* ]]
    diff_usage_error "invalid value for --pr: it must be a number" --repo "${REPO}" --pr "${token}"
    [[ "$(< "${TEST_TMP}/diff-usage-error")" != *"${token}"* ]]

    [ ! -f "${GH_LOG}" ]
}

@test "pr diff prints the diff byte for byte, from one gh pr diff call with colour off and terminal escape sequences left to gh to neutralise" {
    write_diff "${SAMPLE_DIFF}"
    diff_prints_fixture --pr 42
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(cat "${GH_LOG}")" = "${DIFF_CALL}" ]
    [ "$(gh_call_count "--allow-escape-sequences")" -eq 0 ]

    # A number given with leading zeros is that number, without them.
    rm "${GH_LOG}"
    diff_prints_fixture --pr 042
    [ "$(cat "${GH_LOG}")" = "${DIFF_CALL}" ]

    # A diff holding the words gh answers a missing pull request with is still a diff.
    write_diff $'diff --git a/x b/x\n+GraphQL: Could not resolve to a PullRequest with the number of 42.\n'
    diff_prints_fixture --pr 42
}

@test "pr diff prints nothing and exits 0 for a pull request with an empty diff" {
    write_diff ""
    diff_prints_fixture --pr 42
    [ ! -s "${TEST_TMP}/printed-diff" ]
    run_pr_diff
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
}

@test "pr diff prints a diff of exactly 1 MiB, and refuses one a byte longer, counted in bytes, whole, printing none of it" {
    write_sized_diff "${DIFF_BYTE_LIMIT}"
    diff_prints_fixture --pr 42

    write_sized_diff "$((DIFF_BYTE_LIMIT + 1))"
    run_pr_diff
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the diff of ${REPO}#42 is $((DIFF_BYTE_LIMIT + 1)) bytes, more than the ${DIFF_BYTE_LIMIT} cfwf prints, so none is printed; use --stat or --name-only, or git diff on a local checkout" ]

    # Bytes, not characters, whatever the locale: half as many two-byte characters plus one is over.
    LC_ALL=C.UTF-8 bash -c 'v=$(printf "\303\251"); [ "${#v}" -eq 1 ]' || skip "no C.UTF-8 locale on this host"
    write_sized_diff "$((DIFF_BYTE_LIMIT / 2 + 1))" $'\xc3\xa9'
    run --separate-stderr env LC_ALL=C.UTF-8 "${SCRIPT}" pr diff --repo "${REPO}" --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: the diff of ${REPO}#42 is $((DIFF_BYTE_LIMIT + 2)) bytes, more than"* ]]
}

@test "pr diff exits 9 for a pull request that does not exist, the number of an issue included, and 1 for any other failed read, printing nothing" {
    run_pr_diff
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]

    fail_diff "GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)"
    run_pr_diff
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the diff of ${REPO}#42: GraphQL: Could not resolve to a Repository with the name '${REPO}'. (repository)" ]

    fail_diff "HTTP 502: Bad Gateway (https://api.github.com/graphql)"
    run_pr_diff
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the diff of ${REPO}#42: HTTP 502: Bad Gateway (https://api.github.com/graphql)" ]

    # GitHub can refuse to produce a very large diff itself.
    fail_diff $'could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum number of lines (20000)\nsecond line'
    run_pr_diff
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the diff of ${REPO}#42: could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum number of lines (20000)" ]
}

@test "pr diff --name-only prints each file's status letter and path in GitHub's order, the new path of a rename, from the pull request and one paged files read" {
    write_pr_changed_files 7
    write_files "$(diff_file added a.txt 3 0)" "$(diff_file modified b.txt 2 1)" "$(diff_file removed c.txt 0 4)" \
        "$(diff_file renamed d-new.txt 0 0 | jq -c '.previous_filename = "d-old.txt"')" \
        "$(diff_file copied e.txt 5 0 | jq -c '.previous_filename = "a.txt"')" "$(diff_file changed f.sh 0 0)" \
        "$(diff_file unchanged g.txt 0 0)"
    run_pr_diff --name-only
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(tab_line A a.txt)
$(tab_line M b.txt)
$(tab_line D c.txt)
$(tab_line R d-new.txt)
$(tab_line C e.txt)
$(tab_line M f.sh)
$(tab_line - g.txt)" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [ "$(gh_call_count "api ${PULL_ENDPOINT} --jq ")" -eq 1 ]
    [ "$(gh_call_count "api ${FILES_ENDPOINT}?per_page=100 --paginate --jq ")" -eq 1 ]
    [ "$(gh_call_count "pr diff")" -eq 0 ]
}

@test "pr diff --stat prints each file's path, additions and deletions in GitHub's order, a binary file as 0 and 0" {
    write_pr_changed_files 3
    write_files "$(diff_file modified src/a.sh 12 3)" "$(diff_file added image.png 0 0)" "$(diff_file removed old.txt 0 40)"
    run_pr_diff --stat
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(tab_line src/a.sh 12 3)
$(tab_line image.png 0 0)
$(tab_line old.txt 0 40)" ]
    has_field_lines "${output}" 3 3
}

@test "pr diff --name-only and --stat print a tab, a newline or a C1 control in a path as a space, so each file stays one line" {
    write_pr_changed_files 3
    write_files "$(diff_file modified $'a\tb.txt' 1 1)" "$(diff_file added $'c\nM\td.txt' 1 0)" "$(diff_file added $'e\xc2\x85f\x1b[31m' 2 0)"
    run_pr_diff --name-only
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_line M "a b.txt")
$(tab_line A "c M d.txt")
$(tab_line A "e f [31m")" ]
    has_field_lines "${output}" 3 2

    run_pr_diff --stat
    [ "${status}" -eq 0 ]
    has_field_lines "${output}" 3 3
}

@test "pr diff --name-only and --stat print nothing and exit 0 for a pull request that changes no files" {
    write_pr_changed_files 0
    write_files
    local mode
    for mode in --name-only --stat; do
        run_pr_diff "${mode}"
        [ "${status}" -eq 0 ]
        [ -z "${output}" ]
        [ -z "${stderr}" ]
    done
}

@test "pr diff --name-only and --stat read every page of the files list, 100 a page, and print every file in order" {
    write_pr_changed_files 205
    write_files_pages "$(numbered_files_page 1 100)" "$(numbered_files_page 101 200)" "$(numbered_files_page 201 205)"
    run_pr_diff --stat
    [ "${status}" -eq 0 ]
    [ "$(wc -l <<< "${output}")" -eq 205 ]
    [ "${output%%$'\n'*}" = "$(tab_line file-1.txt 1 1)" ]
    [ "$(sed -n 101p <<< "${output}")" = "$(tab_line file-101.txt 101 1)" ]
    [ "${output##*$'\n'}" = "$(tab_line file-205.txt 205 1)" ]
    [ "$(gh_call_count "api ${FILES_ENDPOINT}?per_page=100 --paginate --jq ")" -eq 1 ]

    run_pr_diff --name-only
    [ "${status}" -eq 0 ]
    [ "$(grep -c $'^M\tfile-[0-9]*\\.txt$' <<< "${output}")" -eq 205 ]
}

@test "pr diff --name-only and --stat refuse a files list shorter or longer than the pull request's count, printing nothing" {
    local changed
    for changed in 2 4; do
        write_pr_changed_files "${changed}"
        write_files "$(diff_file added a.txt 1 0)" "$(diff_file added b.txt 1 0)" "$(diff_file added c.txt 1 0)"
        run_pr_diff --name-only
        [ "${status}" -eq 1 ] || { echo "changed_files ${changed}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the files of ${REPO}#42 changed while they were read; nothing is printed" ]
    done

    # A page lost on the way is a list that does not add up.
    write_pr_changed_files 205
    write_files_pages "$(numbered_files_page 1 100)" "$(numbered_files_page 201 205)"
    run_pr_diff --stat
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the files of ${REPO}#42 changed while they were read; nothing is printed" ]
}

@test "pr diff --name-only and --stat list exactly 3000 files, and refuse a pull request of 3001 before reading any page" {
    write_pr_changed_files 3001
    run_pr_diff --stat
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#42 changes 3001 files and GitHub lists at most 3000, so none is printed; use git diff --name-status or --numstat on a local checkout" ]
    [ "$(gh_call_count "${FILES_ENDPOINT}")" -eq 0 ]

    write_pr_changed_files 3000
    local -a pages=()
    local first
    for first in {1..2901..100}; do
        pages+=("$(numbered_files_page "${first}" "$((first + 99))")")
    done
    write_files_pages "${pages[@]}"
    run_pr_diff --name-only
    [ "${status}" -eq 0 ]
    [ "$(wc -l <<< "${output}")" -eq 3000 ]
    [ "${output##*$'\n'}" = "$(tab_line M file-3000.txt)" ]
}

@test "pr diff --name-only and --stat print nothing and exit 1 for a status GitHub has no letter for, or a file whose row is not its fields" {
    write_pr_changed_files 2
    write_files "$(diff_file added a.txt 1 0)" "$(diff_file moved b.txt 1 0)"
    local mode
    for mode in --name-only --stat; do
        run_pr_diff "${mode}"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the files of ${REPO}#42" ]
    done

    local file
    for file in "$(diff_file modified b.txt '"x"' 0)" "$(diff_file modified b.txt 1 null)" "$(diff_file modified b.txt -1 0)" \
        "$(diff_file modified b.txt 1.5 0)" "$(diff_file modified "" 1 0)" "$(diff_file modified b.txt 1 0 | jq -c 'del(.filename)')"; do
        write_files "$(diff_file added a.txt 1 0)" "${file}"
        run_pr_diff --stat
        [ "${status}" -eq 1 ] || { echo "printed: ${file}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the files of ${REPO}#42" ]
    done

    # A row with no closing field, or a field too many, from an answer the program could not give.
    rm "$(api_fixture "${FILES_ENDPOINT}").json"
    local row
    for row in $'modified\x1fb.txt\x1f1\x1f0' $'modified\x1fb.txt\x1f1\x1f0\x1fextra\x1fend'; do
        printf 'added\x1fa.txt\x1f1\x1f0\x1fend\n%s\n' "${row}" > "$(api_fixture "${FILES_ENDPOINT}").out"
        run_pr_diff --stat
        [ "${status}" -eq 1 ] || { echo "printed: ${row}" >&2; return 1; }
        [ -z "${output}" ]
    done
    printf 'added\x1fa.txt\x1f1\x1f0\x1fend\nmodified\x1fb.txt\x1f2\x1f3\x1fend\n' > "$(api_fixture "${FILES_ENDPOINT}").out"
    run_pr_diff --stat
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_line a.txt 1 0)
$(tab_line b.txt 2 3)" ]
}

@test "pr diff --name-only and --stat exit 9 for a pull request that does not exist, and 1 when the repository is not there either" {
    write_repository "${REPO}"
    run_pr_diff --name-only
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    [ "$(gh_call_count "${FILES_ENDPOINT}")" -eq 0 ]

    rm "$(api_fixture "repos/${REPO}").json"
    run_pr_diff --stat
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
}

@test "pr diff --name-only and --stat treat a failed read, a files list that is not there and a pull request of another number as a runtime failure (exit 1), printing nothing" {
    fail_api "${PULL_ENDPOINT}"
    run_pr_diff --name-only
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#42: gh: Bad Gateway (HTTP 502)" ]
    rm "$(api_fixture "${PULL_ENDPOINT}").fail"

    write_pr_changed_files 1
    fail_api "${FILES_ENDPOINT}"
    run_pr_diff --stat
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the files of ${REPO}#42: gh: Bad Gateway (HTTP 502)" ]

    # The pull request was there a moment ago, so a 404 for its files is not a missing pull request.
    rm "$(api_fixture "${FILES_ENDPOINT}").fail"
    write_repository "${REPO}"
    run_pr_diff --stat
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the files of ${REPO}#42" ]

    local filter
    for filter in '.number = 43' '.changed_files = "x"' '.changed_files = null' '.changed_files = 1234567890'; do
        jq -n '{number: 42, changed_files: 1}' | jq "${filter}" | write_api "${PULL_ENDPOINT}"
        write_files "$(diff_file added a.txt 1 0)"
        run_pr_diff --stat
        [ "${status}" -eq 1 ] || { echo "printed for ${filter}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#42" ]
    done
}

@test "pr diff fails (exit 1) when gh is not installed, after the options are checked" {
    mkdir -p "${TEST_TMP}/empty-path"
    write_diff "${SAMPLE_DIFF}"
    local mode
    for mode in "" --name-only --stat; do
        run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr diff --repo "${REPO}" --pr 42 ${mode:+"${mode}"}
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: gh is not installed"* ]]
    done

    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr diff --repo "${REPO}" --pr 0
    [ "${status}" -eq 2 ]
}

# --- pr list --label -----------------------------------------------------------

# A pull_request object (the arguments of pull_request) carrying the labels in LABELS, a space-separated list.
labelled_pull_request() {
    # shellcheck disable=SC2153 # LABELS is set by each caller, e.g. LABELS="a b" labelled_pull_request ...
    pull_request "$@" | jq --arg labels "${LABELS}" '. + {labels: ($labels | split(" ") | map(select(. != "") | {name: .}))}'
}

@test "pr list --label lists only the pull requests carrying every label given, case aside, in the eight-field format, asking gh for them" {
    local a b c
    a=$(LABELS="dependencies" labelled_pull_request 3 depends/a main app/dependabot false false "chore: bump a")
    b=$(LABELS="Dependencies security" labelled_pull_request 5 depends/b main app/dependabot false false "chore: bump b")
    c=$(LABELS="enhancement" labelled_pull_request 8 feat/8-c main someone false false "feat: c")
    write_pr_list "${a}" "${b}" "${c}"

    run_pr_list --label dependencies
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected
    expected="$(pr_list_line 3 depends/a main app/dependabot ready - "chore: bump a")"$'\n'
    expected+="$(pr_list_line 5 depends/b main app/dependabot ready - "chore: bump b")"
    [ "${output}" = "${expected}" ]
    has_eight_field_lines "${output}" 2
    [ "$(gh_call_count "pr list --repo ${REPO} --state open --limit 1001 --label dependencies --json number,title,author,headRefName,baseRefName,isDraft,isCrossRepository,url,labels --jq ")" -eq 1 ]

    run_pr_list --label DEPENDENCIES --label security
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(pr_list_line 5 depends/b main app/dependabot ready - "chore: bump b")" ]

    run_pr_list --label wontfix
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "pr list --label refuses (exit 1) an answer with a pull request that lacks a label asked for, printing nothing" {
    write_pr_list "$(LABELS="enhancement" labelled_pull_request 8 feat/8-c main someone false false "feat: c")"
    touch "${GH_FIXTURES}/pr-list.ignore-label"
    run_pr_list --label dependencies
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the open pull requests of ${REPO}" ]
}

@test "pr list --label combines with --head and --issue, and a label given twice is asked for once" {
    write_pr_list "$(LABELS="dependencies" labelled_pull_request 3 depends/12-a main app/dependabot false false "chore: bump a")" \
        "$(LABELS="dependencies" labelled_pull_request 4 depends/13-b main app/dependabot false false "chore: bump b")"
    run_pr_list --label dependencies --label Dependencies --head depends/12-a --issue 12
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(pr_list_line 3 depends/12-a main app/dependabot ready issue "chore: bump a")" ]
    [ "$(gh_call_count "--label dependencies --label")" -eq 0 ]
    [ "$(gh_call_count "--label Dependencies")" -eq 0 ]
}

@test "pr list refuses (exit 2) a blank, over-long or control-character --label, or one with a double quote or a backslash, before any gh call, never echoing it" {
    local bad
    for bad in "" "   " "$(printf 'a%.0s' {1..51})" $'de\x01ps' $'de\tps' 'de"ps' 'de\ps'; do
        run_pr_list --label "${bad}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == *"invalid value for --label: it must be a label of at most 50 characters"* ]]
        if [ -n "${bad// /}" ]; then
            [[ "${stderr}" != *"${bad}"* ]]
        fi
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr list help documents --label" {
    run "${SCRIPT}" pr list --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[--label <name> ...]"* ]]
    [[ "${output}" == *"must carry every label given"* ]]
    [ ! -f "${GH_LOG}" ]
}

# --- pr status (#1782) -----------------------------------------------------------

STATUS_READY_AT="2026-10-08T12:00:00Z"
STATUS_FIELDS=(state draft title url base head head-sha auto-merge review-decision merge-state mergeable labels
    assignees author board ready-at checks checks-failed checks-pending files comments reviews threads unresolved
    activity-since-ready last-activity)
STATUS_VIEW_JSON="state,isDraft,title,url,baseRefName,headRefName,headRefOid,autoMergeRequest,reviewDecision,mergeStateStatus,mergeable,labels,assignees,author,files,changedFiles"
# PR 42's items on the boards: one on a decoy project, and AI Review on the Workflow project.
STATUS_BOARD_ITEMS='[{"project": {"id": "PVT_other"}, "legacy": null, "status": {"name": "Human Review"}},
    {"project": {"id": "PVT_proj"}, "legacy": null, "status": {"name": "AI Review"}}]'

# Writes the one answer setup's gh stand-in gives every GraphQL call, which serves both reads pr
# status makes with it, each --jq program picking its own part: PR 42's board items $1 (a JSON
# array) for the board read, and the discussion for pr comments' read, the comments $2, the reviews
# $3 and the threads $4, each a discussion_list object.
write_status_graphql() {
    jq -n --argjson items "$1" --argjson comments "$2" --argjson reviews "$3" --argjson threads "$4" \
        '{data: {repository: {pullRequest: {projectItems: {nodes: $items}, reviewDecision: null,
            comments: $comments, reviews: $reviews, reviewThreads: $threads}}}}' > "${GH_FIXTURES}/graphql-target.json"
}

# Writes PR 42's discussion: one top-level comment by credfeto at 2026-10-08T10:17:52Z, before
# STATUS_READY_AT; one review by reviewer at 2026-10-08T14:44:59Z, after it; and one unresolved
# thread. $1 is the board items (STATUS_BOARD_ITEMS by default).
write_status_discussion() {
    write_status_graphql "${1:-${STATUS_BOARD_ITEMS}}" \
        "$(discussion_list 1 false "" "$(issue_comment_node 7 credfeto User "Looks close.")")" \
        "$(discussion_list 1 false "" "$(review_node 8 reviewer User CHANGES_REQUESTED "Please fix the test.")")" \
        "$(discussion_list 1 false "" "$(thread_node false false README.md 3 3 "$(inline_node 500 "" 8 reviewer User "This line.")")")"
}

# PR 42 as write_pull_request writes it (open, ready, one changed file, head HEAD_SHA), AI Review on
# the Workflow board, last marked ready at STATUS_READY_AT; main requires build, which passed; and
# write_status_discussion's discussion. Each test changes what it needs.
prepare_pr_status() {
    write_pull_request
    prepare_pr_checks
    write_issue_kind 42 pull
    write_timeline 42 "$(timeline_event ready_for_review credfeto "" "${STATUS_READY_AT}")"
    write_status_discussion
}

run_pr_status() {
    run --separate-stderr "${SCRIPT}" pr status --repo "${REPO}" --pr 42
}

# Prints the output of prepare_pr_status's pull request, with the values given as name=value in
# place of its own.
status_output() {
    local -A values=(
        ["state"]=OPEN ["draft"]=no ["title"]="feat: add a thing" ["url"]="${PR_URL}" ["base"]=main ["head"]=feat/thing
        ["head-sha"]="${HEAD_SHA}" ["auto-merge"]=off ["review-decision"]="" ["merge-state"]=BLOCKED
        ["mergeable"]=MERGEABLE ["labels"]="" ["assignees"]="" ["author"]=prpixie ["board"]="AI Review"
        ["ready-at"]="${STATUS_READY_AT}" ["checks"]=pass ["checks-failed"]="" ["checks-pending"]="" ["files"]=1
        ["comments"]=1 ["reviews"]=1 ["threads"]=1 ["unresolved"]=1 ["activity-since-ready"]=1
        ["last-activity"]="2026-10-08T14:44:59Z reviewer"
    )
    local change name
    for change in "$@"; do
        values["${change%%=*}"]="${change#*=}"
    done
    for name in "${STATUS_FIELDS[@]}"; do
        printf '%s\t%s\n' "${name}" "${values["${name}"]}"
    done
}

# Nothing was written: pr status only reads.
assert_status_read_only() {
    [ "$(gh_call_count "project item-")" -eq 0 ]
    [ "$(gh_call_count "--method")" -eq 0 ]
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    [ "$(gh_call_count "pr edit")" -eq 0 ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
    [ "$(gh_call_count "issue comment")" -eq 0 ]
    [ "$(gh_call_count "mutation")" -eq 0 ]
}

@test "pr status help, from help pr status, pr status --help and pr status -h, lists every field and exit code and calls no gh" {
    local flag name
    for flag in "pr status --help" "pr status -h" "help pr status"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${flag}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr status --repo <owner/repo> --pr <n>"$'\n'* ]]
        for name in "${STATUS_FIELDS[@]}"; do
            grep -qE "^  ${name} +[A-Za-z0-9]" <<< "${output}" || {
                echo "not listed: ${name}" >&2
                return 1
            }
        done
        [[ "${output}" == *"0 every judged check passed;"$'\n'"3 at least one failed; 4 none failed and at least one is pending; 5 the head has no check runs or"* ]]
        [[ "${output}" == *"9 the pull request does not exist"* ]]
        [[ "${output}" == *"2 a usage error."* ]]
        [[ "${output}" == *"--json, --jq, --template, --field and --all are not options"* ]]
    done
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  pr status                Print a PR's whole state in one call: metadata, board, checks, comments (exit 0, 3, 4, 5 or 9)"$'\n'* ]]
    run "${SCRIPT}" help pr
    [[ "${output}" == *"Run 'cfwf pr status --help' for pr status"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr status usage errors exit 2 before any gh call" {
    local -a call
    local calls=("--repo ${REPO}" "--pr 42" "--repo ${REPO} --pr 0" "--repo ${REPO} --pr abc" "--repo ${REPO} --pr 42 --json state"
        "--repo ${REPO} --pr 42 --field state" "--repo ${REPO} --pr 42 --all" "--repo ${REPO} --pr 42 --pr 43" "--repo owner --pr 42")
    local arguments
    for arguments in "${calls[@]}"; do
        read -ra call <<< "${arguments}"
        run --separate-stderr "${SCRIPT}" pr status "${call[@]}"
        [ "${status}" -eq 2 ] || {
            echo "accepted: ${arguments}" >&2
            return 1
        }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*"Usage: cfwf pr status --repo <owner/repo> --pr <n>"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr status prints every field in the fixed order and exits 0 when the required checks passed, only reading" {
    prepare_pr_status
    run_pr_status
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(status_output)" ]
    [ "$(grep -c . <<< "${output}")" -eq "${#STATUS_FIELDS[@]}" ]
    [ "$(grep -c $'^[a-z-]*\t' <<< "${output}")" -eq "${#STATUS_FIELDS[@]}" ]
    # One pr view read, for its fields and the file count; the commits are never read.
    [ "$(gh_call_count "pr view 42 --repo ${REPO} --json ${STATUS_VIEW_JSON} --jq ")" -eq 1 ]
    [ "$(gh_call_count "pr view")" -eq 1 ]
    # The board read and the discussion read.
    [ "$(gh_call_count "api graphql")" -eq 2 ]
    [ "$(gh_line_of "pr view")" -eq 1 ]
    assert_status_read_only
}

@test "pr status exits 3 and names each failed check when a required check failed, and 4 naming each pending one" {
    prepare_pr_status
    write_protection main build lint test
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)" "$(check_run lint failure 12)" "$(check_run test success 13)"
    run_pr_status
    [ "${status}" -eq 3 ]
    [ "${output}" = "$(status_output checks=fail checks-failed=build,lint)" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)" "$(check_run lint success 12)" "$(check_run test "" 13)"
    run_pr_status
    [ "${status}" -eq 4 ]
    [ "${output}" = "$(status_output checks=pending checks-pending=build,test)" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)" "$(check_run lint success 12)" "$(check_run test "" 13)"
    run_pr_status
    [ "${status}" -eq 3 ]
    [ "${output}" = "$(status_output checks=fail checks-failed=build checks-pending=test)" ]
}

@test "pr status exits 5 with checks none when the head has no check runs or statuses at all" {
    prepare_pr_status
    write_check_runs "${HEAD_SHA}"
    run_pr_status
    [ "${status}" -eq 5 ]
    [ -z "${stderr}" ]
    # The required check has no result, so pr checks judges it pending, as here.
    [ "${output}" = "$(status_output checks=none checks-pending=build)" ]
}

@test "pr status prints a draft never marked ready with its creation time as ready-at, counting the activity since then" {
    prepare_pr_status
    write_pull_request '.isDraft = true | .mergeStateStatus = "DRAFT" | .reviewDecision = "REVIEW_REQUIRED"'
    write_timeline 42 "$(timeline_event labeled credfeto Medium 2026-10-01T10:00:00Z)"
    run_pr_status
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(status_output draft=yes merge-state=DRAFT review-decision=REVIEW_REQUIRED ready-at="${CREATED_AT}" activity-since-ready=2)" ]
}

@test "pr status prints an empty board, not an error, when the repository has no Workflow board" {
    prepare_pr_status
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false},
        {id: "PVT_old", title: "Workflow", number: 3, resourcePath: "/users/credfeto/projects/3", closed: true}]}}' > "${GH_FIXTURES}/repo-view.json"
    run_pr_status
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(status_output board=)" ]
    # No board, so only the discussion is read through GraphQL.
    [ "$(gh_call_count "api graphql")" -eq 1 ]
}

@test "pr status prints an empty board, not an error, when the pull request is not on the Workflow board" {
    prepare_pr_status
    write_status_discussion '[{"project": {"id": "PVT_other"}, "legacy": null, "status": {"name": "Human Review"}}]'
    run_pr_status
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(status_output board=)" ]
}

@test "pr status counts only the top-level comments and submitted reviews after ready-at, and names the newest of all" {
    prepare_pr_status
    write_status_graphql "${STATUS_BOARD_ITEMS}" \
        "$(discussion_list 2 false "" "$(issue_comment_node 7 credfeto User "Before.")" \
            "$(discussion_node issuecomment- 9 octocat User "After." '{"createdAt": "2026-10-09T08:00:00Z", "isMinimized": false}')")" \
        "$(discussion_list 3 false "" "$(review_node 8 reviewer User APPROVED "Fine.")" \
            "$(discussion_node pullrequestreview- 10 pending User "Draft." '{"state": "PENDING", "submittedAt": null}')" \
            "$(discussion_node pullrequestreview- 11 bot Bot "" '{"state": "COMMENTED", "submittedAt": "2026-10-10T08:00:00Z"}')")" \
        "$(empty_list)"
    run_pr_status
    [ "${status}" -eq 0 ]
    # The pending review has no time, and the empty COMMENTED review, the wrapper of inline
    # comments, is not one pr comments prints or counts as a review.
    [ "${output}" = "$(status_output comments=2 reviews=2 threads=0 unresolved=0 activity-since-ready=2 last-activity="2026-10-09T08:00:00Z octocat")" ]

    write_status_graphql "${STATUS_BOARD_ITEMS}" "$(empty_list)" "$(empty_list)" "$(empty_list)"
    run_pr_status
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(status_output comments=0 reviews=0 threads=0 unresolved=0 activity-since-ready=0 last-activity=)" ]
}

@test "pr status prints 100+ files, rather than failing as pr view --field files does, when gh lists fewer than the pull request changes" {
    prepare_pr_status
    write_pull_request '.changedFiles = 250 | .files = [range(100) | {path: "f\(.)", additions: 1, deletions: 0}]'
    run_pr_status
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(status_output files=100+)" ]

    write_pull_request '.changedFiles = 100 | .files = [range(100) | {path: "f\(.)", additions: 1, deletions: 0}]'
    run_pr_status
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(status_output files=100)" ]
}

@test "pr status prints each control character of a value as a space, so a line is always one field" {
    prepare_pr_status
    write_pull_request '.title = "a\tb\nc\u001b[31md" | .labels = [{name: "x\ny"}, {name: "Blocked"}]'
    run_pr_status
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(status_output "title=a b c [31md" "labels=x y,Blocked")" ]
}

@test "pr status exits 9 and prints nothing when the pull request is not there, reading nothing else" {
    prepare_pr_status
    fail_pull_request "GraphQL: Could not resolve to a PullRequest with the number of 42. (repository.pullRequest)"
    run_pr_status
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
}

@test "pr status prints nothing and exits 1 when any read fails part way" {
    local endpoint
    for endpoint in "repos/${REPO}/issues/42/timeline" "repos/${REPO}/branches/main" "repos/${REPO}/commits/${HEAD_SHA}/check-runs"; do
        prepare_pr_status
        fail_api "${endpoint}"
        run_pr_status
        [ "${status}" -eq 1 ] || {
            echo "${endpoint}: exit ${status}" >&2
            return 1
        }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*"(HTTP 502)" ]]
        rm -f "$(api_fixture "${endpoint}").fail"
    done

    # A failed read of the projects, of the board item (both the direct read and the listing), and
    # of the discussion (on a repository with no board, so it is the only GraphQL read).
    prepare_pr_status
    printf 'boom\n' > "${GH_FIXTURES}/repo-view.fail"
    run_pr_status
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not read the projects of ${REPO}" ]]
    rm -f "${GH_FIXTURES}/repo-view.fail"

    printf 'GraphQL: something went wrong\n' > "${GH_FIXTURES}/graphql.fail"
    printf 'boom\n' > "${GH_FIXTURES}/item-list.fail"
    run_pr_status
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not read the status of ${REPO}#42: both the direct query and the listing of project 74 failed" ]]

    jq -n '{projectsV2: {Nodes: []}}' > "${GH_FIXTURES}/repo-view.json"
    run_pr_status
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: GraphQL: something went wrong" ]
}

@test "pr status prints nothing and exits 1 when the head changed between the pull request read and the checks read" {
    prepare_pr_status
    jq -n --arg sha "${OLD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "main"}}' | write_api "repos/${REPO}/pulls/42"
    write_check_runs "${OLD_SHA}" "$(check_run build success 11 "" "${OLD_SHA}")"
    write_statuses "${OLD_SHA}"
    run_pr_status
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the head of ${REPO}#42 changed while it was read, so nothing is printed: run it again" ]
}
