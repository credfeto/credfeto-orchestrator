#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- pr edit -------------------------------------------------------------------

commit_reads() {
    gh_call_count "api repos/${REPO}/pulls/${EDIT_PR}/commits"
}

@test "pr edit changes the title and the body of the agent's own pull request, assigns the agent and prints only the URL" {
    prepare_pr_edit
    run_pr_edit --title "${EDIT_TITLE}" --body-file "${TEST_TMP}/edit-body.md" --assign-self <<< "stray stdin"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    [ -z "${stderr}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --title ${EDIT_TITLE} --body-file BODY --add-assignee ${AGENT}"
    cmp "${TEST_TMP}/edit-body.md" "${GH_FIXTURES}/edit-body.txt"
    [ "$(gh_call_count "--body-file ${TEST_TMP}/edit-body.md")" -eq 0 ]
    # pr edit has no ownership rule, so the commits are never read.
    [ "$(commit_reads)" -eq 0 ]
    [ "$(edits_made)" -eq 1 ]
}

@test "pr edit hands gh only the parts given: a title alone, a body alone, or only --assign-self" {
    prepare_pr_edit
    run_pr_edit --title "${EDIT_TITLE}"
    [ "${status}" -eq 0 ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --title ${EDIT_TITLE}"

    rm -f "${GH_LOG}"
    run_pr_edit --body-file "${TEST_TMP}/edit-body.md"
    [ "${status}" -eq 0 ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --body-file BODY"

    rm -f "${GH_LOG}"
    run_pr_edit --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-assignee ${AGENT}"
    [ "$(gh_call_count "api user")" -eq 1 ]
}

@test "pr edit reads the body from stdin for --body-file -, and refuses an empty or blank body without calling gh" {
    prepare_pr_edit
    run_pr_edit --body-file - <<< "A body from stdin"
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/edit-body.txt")" = "A body from stdin" ]

    rm -f "${GH_LOG}"
    run_pr_edit --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    printf '  \n\t\n' > "${TEST_TMP}/blank.md"
    run_pr_edit --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    run_pr_edit --body-file "${TEST_TMP}/missing.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: cannot read the --body-file" ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr edit edits a pull request a human opened, whoever wrote its commits, without reading the commits" {
    prepare_pr_edit credfeto User 2 credfeto someone-else
    run_pr_edit --title "${EDIT_TITLE}" --body-file "${TEST_TMP}/edit-body.md" --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    [ -z "${stderr}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --title ${EDIT_TITLE} --body-file BODY --add-assignee ${AGENT}"
    cmp "${TEST_TMP}/edit-body.md" "${GH_FIXTURES}/edit-body.txt"
    [ "$(commit_reads)" -eq 0 ]
    [ "$(edits_made)" -eq 1 ]

    # Without --assign-self the agent's login is not needed, so it is not read.
    rm -f "${GH_LOG}"
    run_pr_edit --title "${EDIT_TITLE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --title ${EDIT_TITLE}"
    [ "$(gh_call_count "api user")" -eq 0 ]
    [ "$(commit_reads)" -eq 0 ]
}

@test "pr edit edits a bot's pull request with commits by people, by an author GitHub does not know, none by the agent, or more than GitHub lists, without reading the commits" {
    prepare_pr_edit prpixie User 21 "${AGENT}" "${AGENT}" "${AGENT}" credfeto credfeto ""
    run_pr_edit --title "${EDIT_TITLE}" --body-file "${TEST_TMP}/edit-body.md" --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    [ -z "${stderr}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --title ${EDIT_TITLE} --body-file BODY --add-assignee ${AGENT}"

    rm -f "${GH_LOG}"
    prepare_pr_edit "github-actions[bot]" Bot 1 credfeto
    run_pr_edit --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-assignee ${AGENT}"

    rm -f "${GH_LOG}"
    prepare_pr_edit prpixie User 251 credfeto
    run_pr_edit --body-file "${TEST_TMP}/edit-body.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --body-file BODY"
    [ "$(commit_reads)" -eq 0 ]
    [ "$(edits_made)" -eq 1 ]
}

@test "pr edit exits 9 for a pull request that is not there, and 1 when the repository is not there or a read fails" {
    jq -n --arg login "${AGENT}" '{login: $login}' > "${GH_FIXTURES}/api-user.json"
    jq -n '{id: 1}' | write_api "repos/${REPO}"
    run_pr_edit --assign-self
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#${EDIT_PR} was not found" ]
    [ "$(edits_made)" -eq 0 ]

    rm -f "$(api_fixture "repos/${REPO}").json"
    run_pr_edit --assign-self
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]

    prepare_pr_edit
    fail_api "repos/${REPO}/pulls/${EDIT_PR}"
    run_pr_edit --assign-self
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#${EDIT_PR}: gh: Bad Gateway (HTTP 502)" ]

    prepare_pr_edit
    printf '%s\n' "HTTP 502" > "${GH_FIXTURES}/api-user.fail"
    run_pr_edit --assign-self
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the authenticated user: HTTP 502" ]
    [ "$(edits_made)" -eq 0 ]
}

@test "pr edit refuses an answer that is not this pull request, and quotes gh when the edit fails" {
    prepare_pr_edit
    jq -n --arg author "${AGENT}" '{user: {login: $author, type: "User"}, html_url: "https://github.com/credfeto/credfeto-orchestrator/pull/1601", commits: 1}' \
        | write_api "repos/${REPO}/pulls/${EDIT_PR}"
    run_pr_edit --assign-self
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#${EDIT_PR}" ]
    [ "$(edits_made)" -eq 0 ]

    prepare_pr_edit
    printf '%s\n' "GraphQL: Resource not accessible by integration" > "${GH_FIXTURES}/pr-edit.fail"
    run_pr_edit --assign-self
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not edit ${REPO}#${EDIT_PR}: GraphQL: Resource not accessible by integration" ]
}

@test "pr edit takes a Conventional Commits title and refuses another shape, a blank one, a control character or more than 256 characters (exit 2) without echoing it or calling gh" {
    prepare_pr_edit
    local title
    for title in "Add pr edit LEAKMARKER" "Feat: add LEAKMARKER" "feat:LEAKMARKER" "fix(): add LEAKMARKER"; do
        run_pr_edit --title "${title}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == "cfwf: invalid value for --title: it must be a Conventional Commits title"* ]]
        [[ "${stderr}" != *LEAKMARKER* ]]
    done
    run_pr_edit --title $'feat: a \x1b[1mLEAKMARKER'
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not contain a control character"* ]]
    run_pr_edit --title "   "
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not be blank or longer than 256 characters"* ]]
    run_pr_edit --title "feat: $(run_of x 251)"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not be blank or longer than 256 characters"* ]]
    [ ! -f "${GH_LOG}" ]

    run_pr_edit --title "feat: $(run_of x 250)"
    [ "${status}" -eq 0 ]
    [ "$(edits_made)" -eq 1 ]
}

@test "pr edit refuses a title or a body with a token or a host path (exit 8) before any gh call" {
    prepare_pr_edit
    local leak
    for leak in "token|use gh""p_LEAKMARKER0123456789 here" "host path|see /home/LEAKMARKER/work"; do
        write_leak_body "${leak#*|}"
        run_pr_edit --body-file "${TEST_TMP}/leak.md" --assign-self
        assert_refused "${status}" "${output}" "${stderr}" "${leak%%|*}" "LEAKMARKER"
        run_pr_edit --title "feat: ${leak#*|}"
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: title refused: ${leak%%|*}" ]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr edit usage errors exit 2 with the pr edit usage before any gh call, never echoing a value" {
    prepare_pr_edit
    run --separate-stderr "${SCRIPT}" pr edit --pr "${EDIT_PR}" --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --repo"*"Usage: cfwf pr edit "* ]]
    run --separate-stderr "${SCRIPT}" pr edit --repo "${REPO}" --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --pr"* ]]
    run_pr_edit
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: nothing to change: give --title, --body-file, --priority or --assign-self"* ]]
    run_pr_edit --title "${EDIT_TITLE}" --title "${EDIT_TITLE}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --title can only be given once"* ]]
    run_pr_edit --body-file a --body-file b
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --body-file can only be given once"* ]]
    run_pr_edit --assign-self --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --assign-self can only be given once"* ]]
    run --separate-stderr "${SCRIPT}" pr edit --repo "${REPO}" --pr 0 --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --pr: it must be a number above 0"* ]]
    run --separate-stderr "${SCRIPT}" pr edit --repo "${REPO}" --pr 12a --assign-self
    [ "${status}" -eq 2 ]
    local option
    for option in --add-assignee --remove-assignee --add-label --body --base --json --jq; do
        run_pr_edit --assign-self "${option}" LEAKMARKER
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == "cfwf: unknown option (argument 8; its value is not shown)"*"Usage: cfwf pr edit "* ]]
        [[ "${stderr}" != *LEAKMARKER* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr edit help, from help pr edit, pr edit --help and pr edit -h, gives the usage, says any pull request can be edited and gives the exit codes; help pr and the general help point to it; none calls gh" {
    local invocation
    for invocation in "help pr edit" "pr edit --help" "pr edit -h"; do
        # shellcheck disable=SC2086  # the invocation is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr edit --repo <owner/repo> --pr <n> [--title <title>] [--body-file <file|->] [--priority <priority>] [--assign-self]"* ]]
        [[ "${output}" == *"Any pull request in"*"the repository can be edited, whoever opened it and whoever wrote its commits"* ]]
        [[ "${output}" != *"edit refused"* ]]
        [[ "${output}" != *"PR_CREATOR_LOGIN"* ]]
        [[ "${output}" == *"Exit codes: 0 edited, or nothing to write; 1 a runtime failure"*"the priority by the Security rule, or --assign-self because another"*"user is assigned; 9 the pull request does not exist"* ]]
        [[ "${output}" == *"--priority     Make the pull request's priority Security, Urgent, High, Medium or Low"*"Security is never replaced"* ]]
    done
    run --separate-stderr "${SCRIPT}" help pr
    [[ "${output}" == *$'\n'"Run 'cfwf pr edit --help' for pr edit, which changes a pull request's title, body or priority, or assigns the agent."$'\n'* ]]
    run --separate-stderr "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  pr edit                  Change a PR's title, body or priority, or assign the agent (exit 8 when refused, 9 when not found)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr edit fails (exit 1) when gh is not installed, after the options are checked" {
    prepare_pr_edit
    mkdir -p "${TEST_TMP}/empty-path"
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" pr edit --repo "${REPO}" --pr "${EDIT_PR}" --assign-self
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]
}

# --- issue edit ----------------------------------------------------------------

@test "issue edit changes the title and the body, assigns the agent and prints only the issue URL" {
    prepare_issue_edit
    run_issue_edit --title "${EDIT_ISSUE_TITLE}" --body-file "${TEST_TMP}/edit-body.md" --assign-self <<< "stray stdin"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}" ]
    [ -z "${stderr}" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --title ${EDIT_ISSUE_TITLE} --body-file BODY --add-assignee ${AGENT}"
    cmp "${TEST_TMP}/edit-body.md" "${GH_FIXTURES}/edit-body.txt"
    # gh is given cfwf's private copy of the body, never the caller's file.
    [ "$(gh_call_count "--body-file ${TEST_TMP}/edit-body.md")" -eq 0 ]
    [ "$(issue_edits_made)" -eq 1 ]
}

@test "issue edit hands gh only the parts given: a title alone, a body alone, or only --assign-self" {
    prepare_issue_edit
    run_issue_edit --title "${EDIT_ISSUE_TITLE}"
    [ "${status}" -eq 0 ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --title ${EDIT_ISSUE_TITLE}"
    # The agent's login is read only for --assign-self.
    [ "$(gh_call_count "api user")" -eq 0 ]

    rm -f "${GH_LOG}"
    run_issue_edit --body-file "${TEST_TMP}/edit-body.md"
    [ "${status}" -eq 0 ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --body-file BODY"

    rm -f "${GH_LOG}"
    run_issue_edit --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --add-assignee ${AGENT}"
    [ "$(gh_call_count "api user")" -eq 1 ]
}

@test "issue edit reads the body from stdin for --body-file -, and refuses an empty or blank body without editing" {
    prepare_issue_edit
    run_issue_edit --body-file - <<< "A body from stdin"
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/edit-body.txt")" = "A body from stdin" ]

    rm -f "${GH_LOG}"
    run_issue_edit --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    printf '  \n\t\n' > "${TEST_TMP}/blank.md"
    run_issue_edit --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue edit takes a title of the issue create shape, not only a Conventional Commits one, and refuses another shape, a blank one, a control character or more than 256 characters (exit 2) without echoing it or calling gh" {
    prepare_issue_edit
    local title
    for title in "Add issue edit LEAKMARKER" "Tool(cfwf): add LEAKMARKER" "oneshot:LEAKMARKER"; do
        run_issue_edit --title "${title}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == 'cfwf: invalid value for --title: it must be "prefix: text" or "prefix(name): text"'* ]]
        [[ "${stderr}" != *LEAKMARKER* ]]
    done
    run_issue_edit --title $'oneshot: a \x1b[1mLEAKMARKER'
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not contain a control character"* ]]
    run_issue_edit --title "   "
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not be blank or longer than 256 characters"* ]]
    run_issue_edit --title "oneshot: $(run_of x 248)"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not be blank or longer than 256 characters"* ]]
    [ ! -f "${GH_LOG}" ]

    # A prefix that is not a Conventional Commits type is fine for an issue.
    run_issue_edit --title "oneshot: $(run_of x 247)"
    [ "${status}" -eq 0 ]
    [ "$(issue_edits_made)" -eq 1 ]
}

@test "issue edit refuses a title or a body with a token or a host path (exit 8) before any gh call" {
    prepare_issue_edit
    local leak
    for leak in "token|use gh""p_LEAKMARKER0123456789 here" "host path|see /home/LEAKMARKER/work"; do
        write_leak_body "${leak#*|}"
        run_issue_edit --body-file "${TEST_TMP}/leak.md" --assign-self
        assert_refused "${status}" "${output}" "${stderr}" "${leak%%|*}" "LEAKMARKER"
        run_issue_edit --title "oneshot: ${leak#*|}"
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: title refused: ${leak%%|*}" ]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue edit exits 9 for a number that is no issue or is a pull request's, and 1 when a read fails or the answer is not this issue, writing nothing" {
    jq -n --arg login "${AGENT}" '{login: $login}' > "${GH_FIXTURES}/api-user.json"
    run_issue_edit --assign-self
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#${EDIT_ISSUE} was not found" ]

    jq -n --arg url "https://github.com/${REPO}/pull/${EDIT_ISSUE}" '{url: $url, number: 1596}' > "$(issue_fixture "${EDIT_ISSUE}").json"
    run_issue_edit --assign-self
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${EDIT_ISSUE} is a pull request, not an issue" ]

    jq -n '{url: "https://github.com/credfeto/credfeto-orchestrator/issues/1601", number: 1601}' > "$(issue_fixture "${EDIT_ISSUE}").json"
    run_issue_edit --assign-self
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#${EDIT_ISSUE}" ]

    prepare_issue_edit
    printf '%s\n' "HTTP 502: Bad Gateway" > "$(issue_fixture "${EDIT_ISSUE}").fail"
    run_issue_edit --assign-self
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: could not read ${REPO}#${EDIT_ISSUE}: "*"HTTP 502"* ]]
    rm -f "$(issue_fixture "${EDIT_ISSUE}").fail"

    printf '%s\n' "HTTP 502" > "${GH_FIXTURES}/api-user.fail"
    run_issue_edit --assign-self
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the authenticated user: HTTP 502" ]
    [ "$(issue_edits_made)" -eq 0 ]
}

@test "issue edit quotes gh when the edit fails" {
    prepare_issue_edit
    printf '%s\n' "GraphQL: Resource not accessible by integration" > "${GH_FIXTURES}/issue-edit.fail"
    run_issue_edit --assign-self
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not edit ${REPO}#${EDIT_ISSUE}: GraphQL: Resource not accessible by integration" ]
}

@test "issue edit usage errors exit 2 with the issue edit usage before any gh call, never echoing a value" {
    prepare_issue_edit
    run --separate-stderr "${SCRIPT}" issue edit --issue "${EDIT_ISSUE}" --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --repo"*"Usage: cfwf issue edit "* ]]
    run --separate-stderr "${SCRIPT}" issue edit --repo "${REPO}" --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --issue"* ]]
    run_issue_edit
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: nothing to change: give --title, --body-file, --priority or --assign-self"* ]]
    run_issue_edit --title "${EDIT_ISSUE_TITLE}" --title "${EDIT_ISSUE_TITLE}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --title can only be given once"* ]]
    run_issue_edit --body-file a --body-file b
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --body-file can only be given once"* ]]
    run_issue_edit --assign-self --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --assign-self can only be given once"* ]]
    run --separate-stderr "${SCRIPT}" issue edit --repo "${REPO}" --issue 0 --assign-self
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --issue: it must be a number above 0"* ]]
    run --separate-stderr "${SCRIPT}" issue edit --repo "${REPO}" --issue 12a --assign-self
    [ "${status}" -eq 2 ]
    local option
    for option in --add-assignee --remove-assignee --add-label --remove-label --body --milestone --json --jq --pr; do
        run_issue_edit --assign-self "${option}" LEAKMARKER
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == "cfwf: unknown option (argument 8; its value is not shown)"*"Usage: cfwf issue edit "* ]]
        [[ "${stderr}" != *LEAKMARKER* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue edit help, from help issue edit, issue edit --help and issue edit -h, gives the usage and the exit codes; help issue and the general help list it; none calls gh" {
    local invocation
    for invocation in "help issue edit" "issue edit --help" "issue edit -h"; do
        # shellcheck disable=SC2086  # the invocation is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf issue edit --repo <owner/repo> --issue <n> [--title <title>] [--body-file <file|->] [--priority <priority>] [--assign-self]"* ]]
        [[ "${output}" == *"It need not be a Conventional Commits title"* ]]
        [[ "${output}" == *"Exit codes: 0 edited, or nothing to write; 1 a runtime failure"*"the priority by the Security rule, or --assign-self because another"*"user is assigned; 9 the issue does not exist, or the number is a pull request's."* ]]
        [[ "${output}" == *"--priority     Make the issue's priority Security, Urgent, High, Medium or Low"*"Security is never replaced"* ]]
    done
    run --separate-stderr "${SCRIPT}" help issue
    [[ "${output}" == *"Usage: cfwf issue edit "* ]]
    run --separate-stderr "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  issue edit               Change an issue's title, body or priority, or assign the agent (exit 8 when refused, 9 when not found)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue edit fails (exit 1) when gh is not installed, after the options are checked" {
    prepare_issue_edit
    mkdir -p "${TEST_TMP}/empty-path"
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" issue edit --repo "${REPO}" --issue "${EDIT_ISSUE}" --assign-self
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]
}

# --- issue edit and pr edit --priority -----------------------------------------

# Writes the fixtures of a pr edit --priority run: the agent's own pull request (prepare_pr_edit)
# carrying each argument as a label, and a repository that has every priority label.
prepare_pr_priority() {
    prepare_pr_edit
    jq --args '.labels = ($ARGS.positional | map({name: ., color: "ffffff"}))' "$@" \
        < "$(api_fixture "repos/${REPO}/pulls/${EDIT_PR}").json" > "${TEST_TMP}/pull.json"
    write_api "repos/${REPO}/pulls/${EDIT_PR}" < "${TEST_TMP}/pull.json"
    write_repository_labels Security Urgent High Medium Low Bug
}

# Writes the fixtures of an issue edit --priority run: issue EDIT_ISSUE carrying each argument as a
# label, and a repository that has every priority label.
prepare_issue_priority() {
    prepare_issue_edit
    write_issue "${EDIT_ISSUE}" "tool(cfwf): an old title" OPEN "The old body." "$@"
    write_repository_labels Security Urgent High Medium Low Bug
}

@test "pr edit --priority replaces Medium with Low in one gh pr edit call and prints the change after the URL" {
    prepare_pr_priority Bug Medium
    run_pr_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority Medium -> Low" ]
    [ -z "${stderr}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-label Low --remove-label Medium"
    [ "$(edits_made)" -eq 1 ]
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "issue edit --priority replaces Medium with Low in one gh issue edit call and prints the change after the URL" {
    prepare_issue_priority Bug Medium
    run_issue_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}"$'\n'"priority Medium -> Low" ]
    [ -z "${stderr}" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --add-label Low --remove-label Medium"
    [ "$(issue_edits_made)" -eq 1 ]
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "pr edit --priority adds Low to a pull request with no priority label, creating the label first when the repository lacks it" {
    prepare_pr_priority Bug
    write_repository_labels Security Urgent High Medium Bug
    run_pr_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority none -> Low" ]
    grep -qxF "label create --repo ${REPO} --color cc8899 --description Low Priority -- Low" "${GH_LOG}"
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-label Low"
    [ "$(gh_line_of "label create")" -lt "$(gh_line_of "pr edit ${EDIT_PR} ")" ]
    [ "$(edits_made)" -eq 1 ]
}

@test "issue edit --priority adds Low to an issue with no priority label, creating the label first when the repository lacks it" {
    prepare_issue_priority Bug
    write_repository_labels Security Urgent High Medium Bug
    run_issue_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}"$'\n'"priority none -> Low" ]
    grep -qxF "label create --repo ${REPO} --color cc8899 --description Low Priority -- Low" "${GH_LOG}"
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --add-label Low"
    [ "$(gh_line_of "label create")" -lt "$(gh_line_of "issue edit ${EDIT_ISSUE} ")" ]
    [ "$(issue_edits_made)" -eq 1 ]
}

@test "pr edit --priority leaves exactly one priority label on a pull request that had two" {
    prepare_pr_priority High Bug Low
    run_pr_edit --priority Medium
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority High,Low -> Medium" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-label Medium --remove-label High --remove-label Low"
    [ "$(edits_made)" -eq 1 ]

    # The one asked for among others is kept, and only the others are removed.
    rm -f "${GH_LOG}"
    prepare_pr_priority High Low
    run_pr_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority High,Low -> Low" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --remove-label High"
    [ "$(gh_call_count "label list")" -eq 0 ]
}

@test "issue edit --priority leaves exactly one priority label on an issue that had two" {
    prepare_issue_priority High Bug Low
    run_issue_edit --priority Medium
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}"$'\n'"priority High,Low -> Medium" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --add-label Medium --remove-label High --remove-label Low"
    [ "$(issue_edits_made)" -eq 1 ]

    rm -f "${GH_LOG}"
    prepare_issue_priority High Low
    run_issue_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}"$'\n'"priority High,Low -> Low" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --remove-label High"
    [ "$(gh_call_count "label list")" -eq 0 ]
}

@test "pr edit --priority writes nothing when the pull request already has only that priority, and prints only the URL" {
    prepare_pr_priority Bug Low
    run_pr_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    [ -z "${stderr}" ]
    [ "$(edits_made)" -eq 0 ]
    [ "$(gh_call_count "label ")" -eq 0 ]
}

@test "issue edit --priority writes nothing when the issue already has only that priority, and prints only the URL" {
    prepare_issue_priority Bug Low
    run_issue_edit --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}" ]
    [ -z "${stderr}" ]
    [ "$(issue_edits_made)" -eq 0 ]
    [ "$(gh_call_count "label ")" -eq 0 ]
}

@test "pr edit --priority with --title makes one gh pr edit call holding both, and a title alone is still written when the priority is already set" {
    prepare_pr_priority Medium
    run_pr_edit --title "${EDIT_TITLE}" --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority Medium -> Low" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --title ${EDIT_TITLE} --add-label Low --remove-label Medium"
    [ "$(edits_made)" -eq 1 ]

    rm -f "${GH_LOG}"
    prepare_pr_priority Low
    run_pr_edit --title "${EDIT_TITLE}" --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --title ${EDIT_TITLE}"
    [ "$(edits_made)" -eq 1 ]
}

@test "issue edit --priority with --title makes one gh issue edit call holding both, and a title alone is still written when the priority is already set" {
    prepare_issue_priority Medium
    run_issue_edit --title "${EDIT_ISSUE_TITLE}" --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}"$'\n'"priority Medium -> Low" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --title ${EDIT_ISSUE_TITLE} --add-label Low --remove-label Medium"
    [ "$(issue_edits_made)" -eq 1 ]

    rm -f "${GH_LOG}"
    prepare_issue_priority Low
    run_issue_edit --title "${EDIT_ISSUE_TITLE}" --priority Low
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --title ${EDIT_ISSUE_TITLE}"
    [ "$(issue_edits_made)" -eq 1 ]
}

@test "pr edit --priority refuses (exit 8) to replace Security, writing nothing, not even the title; Security itself drops the other priorities" {
    prepare_pr_priority Security
    run_pr_edit --title "${EDIT_TITLE}" --priority Low
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: priority refused: Security is never replaced by --priority" ]
    [ "$(edits_made)" -eq 0 ]
    [ "$(gh_call_count "label ")" -eq 0 ]

    prepare_pr_priority Low security
    run_pr_edit --priority urgent
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: priority refused: Security is never replaced by --priority" ]
    [ "$(edits_made)" -eq 0 ]

    rm -f "${GH_LOG}"
    run_pr_edit --priority Security
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority Low,security -> Security" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --remove-label Low"
}

@test "issue edit --priority refuses (exit 8) to replace Security, writing nothing, not even the title; Security itself drops the other priorities" {
    prepare_issue_priority Security
    run_issue_edit --title "${EDIT_ISSUE_TITLE}" --priority Low
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: priority refused: Security is never replaced by --priority" ]
    [ "$(issue_edits_made)" -eq 0 ]
    [ "$(gh_call_count "label ")" -eq 0 ]

    prepare_issue_priority Low security
    run_issue_edit --priority urgent
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: priority refused: Security is never replaced by --priority" ]
    [ "$(issue_edits_made)" -eq 0 ]

    rm -f "${GH_LOG}"
    run_issue_edit --priority Security
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}"$'\n'"priority Low,security -> Security" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --remove-label Low"
}

@test "pr edit --priority refuses an unknown priority, or one given twice (exit 2), before any gh call" {
    prepare_pr_priority Medium
    run_pr_edit --priority Critical
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown --priority (expected Security, Urgent, High, Medium or Low)"*"Usage: cfwf pr edit "* ]]
    run_pr_edit --priority Low --priority Low
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --priority can only be given once: a pull request has exactly one priority"* ]]
    run_pr_edit --priority
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue edit --priority refuses an unknown priority, or one given twice (exit 2), before any gh call" {
    prepare_issue_priority Medium
    run_issue_edit --priority Critical
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown --priority (expected Security, Urgent, High, Medium or Low)"*"Usage: cfwf issue edit "* ]]
    run_issue_edit --priority Low --priority Low
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --priority can only be given once: an issue has exactly one priority"* ]]
    run_issue_edit --priority
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr edit --priority exits 9 for a pull request that is not there, writing nothing" {
    jq -n --arg login "${AGENT}" '{login: $login}' > "${GH_FIXTURES}/api-user.json"
    jq -n '{id: 1}' | write_api "repos/${REPO}"
    write_repository_labels Security Urgent High Medium Low
    run_pr_edit --priority Low
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#${EDIT_PR} was not found" ]
    [ "$(edits_made)" -eq 0 ]
    [ "$(gh_call_count "label ")" -eq 0 ]
}

@test "issue edit --priority exits 9 for an issue that is not there, or a pull request's number, writing nothing" {
    write_repository_labels Security Urgent High Medium Low
    run_issue_edit --priority Low
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#${EDIT_ISSUE} was not found" ]
    jq -n --arg url "https://github.com/${REPO}/pull/${EDIT_ISSUE}" '{url: $url, number: 1596, labels: [{name: "Medium"}]}' > "$(issue_fixture "${EDIT_ISSUE}").json"
    run_issue_edit --priority Low
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${EDIT_ISSUE} is a pull request, not an issue" ]
    [ "$(issue_edits_made)" -eq 0 ]
    [ "$(gh_call_count "label ")" -eq 0 ]
}

@test "pr edit --priority takes a priority in any case and writes it in its standard spelling, removing an old one in the pull request's own spelling" {
    prepare_pr_priority medium
    run_pr_edit --priority lOW
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority medium -> Low" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-label Low --remove-label medium"

    # A priority carried in another case is the one asked for: nothing is written.
    rm -f "${GH_LOG}"
    run_pr_edit --priority MEDIUM
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_PR_URL}" ]
    [ "$(edits_made)" -eq 0 ]
}

@test "issue edit --priority takes a priority in any case and writes it in its standard spelling, removing an old one in the issue's own spelling" {
    prepare_issue_priority medium
    run_issue_edit --priority lOW
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}"$'\n'"priority medium -> Low" ]
    issue_create_called_with "issue edit ${EDIT_ISSUE} --repo ${REPO} --add-label Low --remove-label medium"

    rm -f "${GH_LOG}"
    run_issue_edit --priority MEDIUM
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EDIT_ISSUE_URL}" ]
    [ "$(issue_edits_made)" -eq 0 ]
}

@test "pr edit --priority changes the priority of a pull request someone else opened, with no ownership refusal" {
    prepare_pr_priority Medium
    jq '.user.login = "someone-else"' < "$(api_fixture "repos/${REPO}/pulls/${EDIT_PR}").json" > "${TEST_TMP}/pull.json"
    write_api "repos/${REPO}/pulls/${EDIT_PR}" < "${TEST_TMP}/pull.json"
    run_pr_edit --priority Low
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${EDIT_PR_URL}"$'\n'"priority Medium -> Low" ]
    issue_create_called_with "pr edit ${EDIT_PR} --repo ${REPO} --add-label Low --remove-label Medium"
    [ "$(edits_made)" -eq 1 ]
}
