#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- pr create ------------------------------------------------------------------

NEW_PR_URL="https://github.com/credfeto/credfeto-orchestrator/pull/1700"
EXISTING_PR_URL="https://github.com/credfeto/credfeto-orchestrator/pull/1650"
PR_HEAD_BRANCH="feat/1513-thing"
PR_TITLE="feat(cfwf): add a thing"
PR_CREATE_USAGE="Usage: cfwf pr create --repo <owner/repo> --head <branch> --title <title> --body-file <file|-> [--base <branch>]"
PR_EXISTS_NOTE="cfwf: note: an open pull request already exists for the --head (base main); its title and body were not changed"
PR_DEVELOPMENT_EDIT="project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_4"

# The fixtures "pr create" needs on top of setup: a body file, a repository with no open pull
# request whose default branch is main, the head branch, pushed, and the URL gh prints for a new
# pull request. The default board is converted, so Development is st_4.
prepare_pr_create() {
    printf 'The body of the pull request.\n\nCloses #1513\n' > "${TEST_TMP}/pr-body.md"
    write_pr_list
    jq -n '{default_branch: "main"}' | write_api "repos/${REPO}"
    write_head_branch "${PR_HEAD_BRANCH}"
    printf '%s\n' "${NEW_PR_URL}" > "${GH_FIXTURES}/pr-create.out"
}

# Writes the answer to the read of the branch at the API path $1, which names itself $2 (the path
# when not given).
write_head_branch() {
    jq -n --arg name "${2:-$1}" '{name: $name}' | write_api "repos/${REPO}/branches/$1"
}

pr_create_args() {
    PR_CREATE_ARGS=(pr create --repo "${REPO}" --head "${PR_HEAD_BRANCH}" --title "${PR_TITLE}" --body-file "${TEST_TMP}/pr-body.md")
}

# Runs pr create with the usual options, then any given.
run_pr_create() {
    pr_create_args
    run --separate-stderr "${SCRIPT}" "${PR_CREATE_ARGS[@]}" "$@"
}

# Runs pr create with the usual options, but the value $2 for the option $1.
run_pr_create_replacing() {
    local index
    pr_create_args
    for index in "${!PR_CREATE_ARGS[@]}"; do
        if [ "${PR_CREATE_ARGS[index]}" = "$1" ]; then
            PR_CREATE_ARGS[index + 1]="$2"
        fi
    done
    run --separate-stderr "${SCRIPT}" "${PR_CREATE_ARGS[@]}"
}

# Runs pr create with the usual options but the title $1.
run_pr_create_titled() {
    run_pr_create_replacing --title "$1"
}

# Runs pr create with the usual options but the body file $1.
run_pr_create_with_body() {
    run_pr_create_replacing --body-file "$1"
}

# The open pull request 1650 of the head branch, in this repository: $1 its base (main), $2 whether
# it is a draft (true).
existing_pull_request() {
    pull_request 1650 "${PR_HEAD_BRANCH}" "${1:-main}" someone "${2:-true}" false "feat: opened earlier"
}

# Writes the answer to the single-item board read of a pull request: its state on the Workflow
# project, unset for an item with no state, or absent for one that is not on that project. It is
# always on a decoy project too, at Complete, so the project filter matters.
write_pr_board_status() {
    # $state is a jq variable, not a shell one.
    # shellcheck disable=SC2016
    local workflow_item='[{project: {id: "PVT_proj"}, legacy: null, status: {name: $state}}]'
    case "$1" in
        absent) workflow_item='[]' ;;
        unset) workflow_item='[{project: {id: "PVT_proj"}, legacy: null, status: null}]' ;;
    esac
    jq -n --arg state "$1" "{data: {repository: {pullRequest: {projectItems: {nodes:
        ([{project: {id: \"PVT_other\"}, legacy: null, status: {name: \"Complete\"}}] + ${workflow_item})}}}}}" \
        > "${GH_FIXTURES}/graphql-target.json"
}

# Nothing was written: no pull request and no board item.
assert_no_pull_request_created() {
    [ "$(gh_call_count "pr create --repo")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

# The pull request at the URL $1 was put on the board as Development, with one edit.
assert_set_to_development() {
    grep -qxF "project item-add 74 --owner credfeto --url $1 --format json --jq .id" "${GH_LOG}"
    grep -qxF "${PR_DEVELOPMENT_EDIT}" "${GH_LOG}"
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "pr create help gives the usage, each option and its default, the already-exists behaviour and the exit codes, help pr and the general help point to it, and none calls gh" {
    local invocation
    for invocation in "pr create --help" "pr create -h" "help pr create"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${PR_CREATE_USAGE}"$'\n'* ]]
        [[ "${output}" == *"--repo       Always required; never taken from the current directory."* ]]
        [[ "${output}" == *"--head       Always required: the name of the head branch, which must already be pushed"* ]]
        [[ "${output}" == *"--title      Always required: a Conventional Commits title, <type>[(<scope>)][!]: <description>,"* ]]
        [[ "${output}" == *"At most 256"$'\n'*"characters. It is checked for leaks as the body is."* ]]
        [[ "${output}" == *"--body-file  Always required"*"There is no --body."* ]]
        [[ "${output}" == *"--base       Optional: the branch to merge into. Default: the repository's default branch, read"$'\n'*"from GitHub. It must not be the --head."* ]]
        [[ "${output}" == *"always a draft and always Development: there is no --draft, --ready or --status"* ]]
        [[ "${output}" == *"Everything is checked before anything is created"*"a bad call leaves no pull request behind."* ]]
        [[ "${output}" == *"The body is checked for leaks before anything is read from the board or created"*"exits 8 with \"cfwf: body refused: <rule>\""*"\"cfwf: title refused:"* ]]
        [[ "${output}" == *"an open one in this repository whose"$'\n'"head branch is exactly --head, whatever its base; one from a fork's branch of the same name is"$'\n'"ignored."* ]]
        [[ "${output}" == *"the create is never run twice"* ]]
        [[ "${output}" == *"its title, body and draft state are neither read nor changed"* ]]
        [[ "${output}" == *$'\n'"  cfwf: note: an open pull request already exists for the --head (base <base>); its title and body were not changed"$'\n'* ]]
        [[ "${output}" == *"Its Workflow status only moves forward"*"one at Development or later is left as it is"* ]]
        [[ "${output}" == *"\"cfwf: the pull request was already created: <url>\""*"\"cfwf: the pull request already exists: <url>\""* ]]
        [[ "${output}" == *"board write is never read back."* ]]
        [[ "${output}" == *"Exit codes: 0 created, or it already existed; 1 a runtime failure"*"2 a usage error; 8 the"$'\n'"body or the title was refused by the leak check." ]]
    done

    for invocation in "help pr" "pr -h" "pr --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr checks"*$'\n'"Run 'cfwf pr create --help' for pr create, which creates a draft pull request on the Workflow board."$'\n'"Run 'cfwf pr edit --help' for pr edit, which changes a pull request's title, body or priority, or assigns the agent."$'\n'"Run 'cfwf pr close --help' for pr close, which closes a pull request without merging it."$'\n'"Run 'cfwf pr reopen --help' for pr reopen, which reopens a closed pull request."$'\n'"Run 'cfwf pr block --help' for pr block, which posts a question on a pull request and adds Blocked."$'\n'"Run 'cfwf help pr unblock' for pr unblock, for humans only, which posts a comment on a pull request"$'\n'"and removes Blocked."$'\n'"Run 'cfwf branch required-checks --help' for branch required-checks, which lists the checks a branch"$'\n'"requires without judging them." ]]
    done

    run "${SCRIPT}" help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"  pr create                Create a draft PR and put it on the Workflow board as Development (prints the existing one's URL if the branch has one)"$'\n'"  pr edit "*$'\n'"  comment add "* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr create needs --repo, --head, --title and --body-file, takes each option once, and never calls gh otherwise" {
    prepare_pr_create
    pr_create_args
    local flag index
    # Each required option is left out in turn: it and its value are two of the arguments.
    for index in 2 4 6 8; do
        flag="${PR_CREATE_ARGS[index]}"
        run --separate-stderr "${SCRIPT}" "${PR_CREATE_ARGS[@]:0:index}" "${PR_CREATE_ARGS[@]:index+2}"
        [ "${status}" -eq 2 ] || { echo "ran without ${flag}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: missing required option ${flag}"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]]
    done

    for flag in --repo --head --title --body-file; do
        run_pr_create "${flag}" other/value
        [ "${status}" -eq 2 ] || { echo "${flag} was taken twice" >&2; return 1; }
        [[ "${stderr}" == "cfwf: ${flag} can only be given once"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]]
    done
    run_pr_create --base main --base develop
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --base can only be given once"* ]]

    run_pr_create --base
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --base needs a value"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr create is always a draft at Development from a body file: --draft, --ready, --status, --body and the rest are unknown options" {
    prepare_pr_create
    local flag
    for flag in --draft --ready --status --body --label --assignee --reviewer --fill --web --json --jq --pr --issue --priority; do
        run_pr_create "${flag}" value
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: unknown option (argument 11; its value is not shown)"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]]
    done
    run_pr_create extra
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr create refuses a --head or a --base git would not allow, the owner:branch form or one holding a control character, without echoing it, and a --base that is the --head" {
    prepare_pr_create
    local flag branch
    for flag in --head --base; do
        for branch in "" "-x" "a..b" "a b" "HEAD" "owner:branch" "credfeto:${PR_HEAD_BRANCH}" $'feat/a\tLEAKMARKER' $'feat/LEAKMARKER\xc2\x9bb'; do
            # The bad value comes first, so it is parsed before the --head of the usual options.
            run --separate-stderr "${SCRIPT}" pr create "${flag}" "${branch}" --repo "${REPO}" --head "${PR_HEAD_BRANCH}" --title "${PR_TITLE}" --body-file "${TEST_TMP}/pr-body.md"
            [ "${status}" -eq 2 ] || { printf 'accepted: %s %q (%s)\n' "${flag}" "${branch}" "${status}" >&2; return 1; }
            [ -z "${output}" ]
            [[ "${stderr}" == "cfwf: invalid value for ${flag}: it must be a branch name git allows, with no control character"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]]
            [[ "${stderr}" != *LEAKMARKER* ]]
        done
    done

    run_pr_create --base "${PR_HEAD_BRANCH}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --base and --head must be different branches"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]]
    [[ "${stderr}" != *"${PR_HEAD_BRANCH}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr create refuses a --repo that is not <owner>/<repo>, or whose owner or repository is . or .., without echoing it or calling gh" {
    prepare_pr_create
    local row
    for row in "LEAKMARKER|it must be <owner>/<repo>" "LEAKMARKER/a/b|it must be <owner>/<repo>" "LEAKMARKER/a b|it must be <owner>/<repo>" "|it must be <owner>/<repo>" \
        "./LEAKMARKER|neither the owner nor the repository can be . or .." "LEAKMARKER/..|neither the owner nor the repository can be . or .."; do
        run_pr_create_replacing --repo "${row%|*}"
        [ "${status}" -eq 2 ] || { echo "accepted: ${row%|*}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: invalid value for --repo: ${row#*|}"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]]
        [[ "${stderr}" != *LEAKMARKER* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr create takes a Conventional Commits title and refuses any other shape (exit 2) without echoing it or calling gh" {
    prepare_pr_create
    local title
    for title in "feat: x" "fix(cfwf): x" "feat!: x" "chore(a-b)!: x" "tool(cfwf): add a command"; do
        run_pr_create_titled "${title}"
        [ "${status}" -eq 0 ] || { echo "refused: ${title}" >&2; return 1; }
        issue_create_called_with "pr create --repo ${REPO} --head ${PR_HEAD_BRANCH} --base main --draft --title ${title} --body-file BODY"
    done

    : > "${GH_LOG}"
    for title in "Feat: LEAKMARKER" "feat:LEAKMARKER" "feat : LEAKMARKER" "feat(): LEAKMARKER" "feat(a)(b): LEAKMARKER" ": LEAKMARKER" \
        "feat:  LEAKMARKER" "Add a LEAKMARKER" "[Dependencies] Bump LEAKMARKER" "feat(a: LEAKMARKER" "feat1: LEAKMARKER" " feat: LEAKMARKER" "feat!!: LEAKMARKER" "feat: "; do
        run_pr_create_titled "${title}"
        [ "${status}" -eq 2 ] || { echo "accepted: ${title}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: invalid value for --title: it must be a Conventional Commits title, <type>[(<scope>)][!]: <description>"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]]
        [[ "${stderr}" != *LEAKMARKER* ]]
    done
    [ ! -s "${GH_LOG}" ]
}

@test "pr create refuses a Conventional Commits title whose description is only invisible characters (exit 2) without echoing it, and takes one starting with a non-ASCII letter" {
    prepare_pr_create
    local title
    # U+3000, U+00A0, U+200B and U+FEFF: the C locale match sees a byte that is not a space.
    for title in "feat: $(printf '\343\200\200')" "fix: $(printf '\302\240')" "fix: $(printf '\342\200\213')" "fix: $(printf '\357\273\277')"; do
        run_pr_create_titled "${title}"
        [ "${status}" -eq 2 ] && [ -z "${output}" ] \
            && [[ "${stderr}" == "cfwf: invalid value for --title: it must be a Conventional Commits title, <type>[(<scope>)][!]: <description>"$'\n\n'"${PR_CREATE_USAGE}"$'\n'* ]] \
            && [[ "${stderr}" != *"${title}"* ]] \
            || { echo "not refused for its description: ${title}" >&2; return 1; }
    done
    [ ! -f "${GH_LOG}" ]

    for title in "fix: $(printf '\303\251')" "fix: $(printf '\343\200\200')x"; do
        run_pr_create_titled "${title}"
        [ "${status}" -eq 0 ] || { echo "refused: ${title}" >&2; return 1; }
        issue_create_called_with "pr create --repo ${REPO} --head ${PR_HEAD_BRANCH} --base main --draft --title ${title} --body-file BODY"
    done
}

@test "pr create refuses a blank title, one with a control character and one over 256 characters, without echoing it" {
    prepare_pr_create
    run_pr_create_titled "   "
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not be blank or longer than 256 characters"* ]]

    run_pr_create_titled $'feat: LEAKMARKER\tx'
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not contain a control character"* && "${stderr}" != *LEAKMARKER* ]]

    run_pr_create_titled "feat: $(run_of x 251)"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not be blank or longer than 256 characters"* ]]
    [ ! -f "${GH_LOG}" ]

    run_pr_create_titled "feat: $(run_of x 250)"
    [ "${status}" -eq 0 ]
}

@test "pr create refuses, as blank, a title made only of invisible characters, and never echoes it" {
    prepare_pr_create
    local value
    invisible_only_values
    for value in "${INVISIBLE_ONLY_VALUES[@]}"; do
        run_pr_create_titled "${value}"
        assert_refused_as_blank "${status}" "${output}" "${stderr}" --title 256 "${value}" \
            || { echo "the title '${value}' was not refused as blank" >&2; return 1; }
    done
}

@test "pr create counts a title of two-byte characters in characters, in any locale: 256 are taken and 257 refused" {
    LC_ALL=C.UTF-8 bash -c 'v=$(printf "\303\251"); [ "${#v}" -eq 1 ]' || skip "no C.UTF-8 locale on this host"
    prepare_pr_create
    local accented
    accented=$(printf '\303\251%.0s' {1..250})
    LC_ALL=C run_pr_create_titled "feat: ${accented}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_PR_URL}" ]

    : > "${GH_LOG}"
    LC_ALL=C run_pr_create_titled "feat: x${accented}"
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: invalid value for --title: it must not be blank or longer than 256 characters"* ]]
    [ ! -s "${GH_LOG}" ]
}

@test "pr create refuses a missing, unreadable, empty or blank body as a runtime failure, without calling gh" {
    prepare_pr_create
    run_pr_create
    [ "${status}" -eq 0 ]
    : > "${GH_LOG}"

    local row
    : > "${TEST_TMP}/empty.md"
    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    for row in "nope.md|cannot read the --body-file" ".|cannot read the --body-file" "empty.md|the body is empty" "blank.md|the body is empty"; do
        run_pr_create_with_body "${TEST_TMP}/${row%|*}"
        [ "${status}" -eq 1 ] || { echo "took ${row%|*}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: ${row#*|}" ] || { echo "wrong message for ${row%|*}" >&2; return 1; }
    done
    [ ! -s "${GH_LOG}" ]
}

@test "pr create takes a body only from a regular file: /dev/stdin and a pipe are refused, never read, without naming the path or calling gh" {
    prepare_pr_create
    run_pr_create_with_body <(printf 'A body from a pipe\n')
    [ "${status}" -eq 1 ] || { echo "took a pipe" >&2; return 1; }
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: cannot read the --body-file" ]

    run_pr_create_with_body /dev/stdin < /dev/null
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: cannot read the --body-file" ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr create reads the body from stdin for --body-file -, gives gh no stdin, and refuses an empty stdin" {
    prepare_pr_create
    run_pr_create_with_body - <<< "A body from stdin"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_PR_URL}" ]
    [ "$(cat "${GH_FIXTURES}/pr-body.txt")" = "A body from stdin" ]
    [ "$(cat "${GH_FIXTURES}/pr-create.stdin.txt")" = "/dev/null" ]

    : > "${GH_LOG}"
    run_pr_create_with_body - < /dev/null
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ ! -s "${GH_LOG}" ]
}

@test "pr create hands gh the private copy of the body it checked, unchanged, so a body file rewritten after the check is never posted" {
    prepare_pr_create
    cp "${TEST_TMP}/pr-body.md" "${TEST_TMP}/checked.md"
    printf '%s\n' "${TEST_TMP}/pr-body.md" > "${GH_FIXTURES}/pr-list.rewrite"
    run_pr_create
    [ "${status}" -eq 0 ]
    # The rewrite happened, between the check and the create, and gh still got the checked text.
    [[ "$(cat "${TEST_TMP}/pr-body.md")" == rewritten* ]]
    cmp "${TEST_TMP}/checked.md" "${GH_FIXTURES}/pr-body.txt"
    [ "$(gh_call_count "--body-file ${TEST_TMP}/pr-body.md")" -eq 0 ]
}

@test "pr create refuses a body or a title with a token, a host path, a control character or invalid UTF-8 (exit 8) before any gh call, whether or not a pull request exists" {
    prepare_pr_create
    local leak rule existing
    for existing in no yes; do
        [ "${existing}" = no ] || write_pr_list "$(existing_pull_request)"
        for leak in "token|use gh""p_LEAKMARKER0123456789 here" "host path|see /home/LEAKMARKER/work" $'control character|a \x1b[1mLEAKMARKER' $'invalid UTF-8|a \x85 LEAKMARKER'; do
            rule="${leak%%|*}"
            write_leak_body "${leak#*|}"
            run_pr_create_with_body "${TEST_TMP}/leak.md"
            assert_refused "${status}" "${output}" "${stderr}" "${rule}" "LEAKMARKER"
        done

        for leak in "token|feat: use gh""p_LEAKMARKER0123456789" "host path|feat: read /home/LEAKMARKER/work"; do
            run_pr_create_titled "${leak#*|}"
            [ "${status}" -eq 8 ]
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: title refused: ${leak%%|*}" ]
        done
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr create refuses a body or a title naming a private repository on a public target, after the visibility lookup and before any board read" {
    prepare_pr_create
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see https://github.com/credfeto/hidden-thing/issues/4"
    run_pr_create_with_body "${TEST_TMP}/leak.md"
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    [ "$(visibility_lookups credfeto/hidden-thing)" -eq 1 ]

    run_pr_create_titled "feat: port credfeto/hidden-thing#3"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: title refused: private repository" ]

    [ "$(gh_call_count "--json projectsV2")" -eq 0 ]
    [ "$(gh_call_count "project field-list")" -eq 0 ]
    [ "$(gh_call_count "pr list")" -eq 0 ]
    assert_no_pull_request_created
}

@test "pr create fails, creating nothing, when the repository has no Workflow board, two of them, or a board with no Development option" {
    prepare_pr_create
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false}]}}' > "${GH_FIXTURES}/repo-view.json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: no project titled Workflow is linked to ${REPO}" ]

    jq -n '{projectsV2: {Nodes: [range(1; 3) | {id: "PVT_\(.)", title: "Workflow", number: ., resourcePath: "/users/credfeto/projects/\(.)", closed: false}]}}' > "${GH_FIXTURES}/repo-view.json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: more than one project titled Workflow is linked to ${REPO}" ]

    write_repo_view "/users/credfeto/projects/74"
    jq -n '{fields: [{id: "PVTSSF_status", name: "Status", options: [{id: "st_2", name: "Planning"}], type: "ProjectV2SingleSelectField"}], totalCount: 1}' > "${GH_FIXTURES}/field-list.json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: project 74 has no 'Development' option on its Status field" ]

    [ -z "${output}" ]
    [ "$(gh_call_count "pr list")" -eq 0 ]
    assert_no_pull_request_created
}

@test "pr create makes a draft pull request into the default branch, puts it on the board as Development and prints only the URL" {
    prepare_pr_create
    run_pr_create
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_PR_URL}" ]
    [ -z "${stderr}" ]

    issue_create_called_with "pr create --repo ${REPO} --head ${PR_HEAD_BRANCH} --base main --draft --title ${PR_TITLE} --body-file BODY"
    [ "$(gh_call_count "pr create --repo")" -eq 1 ]
    cmp "${TEST_TMP}/pr-body.md" "${GH_FIXTURES}/pr-body.txt"
    [ "$(cat "${GH_FIXTURES}/pr-create.stdin.txt")" = "/dev/null" ]
    assert_set_to_development "${NEW_PR_URL}"
}

@test "pr create checks everything first: board, open pull requests, repository, head branch, then the create and the board writes, and never reads back" {
    prepare_pr_create
    run_pr_create
    [ "${status}" -eq 0 ]
    local -a calls=("repo view" "project field-list" "pr list --repo ${REPO} --state open --limit 1001 --head ${PR_HEAD_BRANCH} " "api repos/${REPO} --jq .default_branch"
        "api repos/${REPO}/branches/${PR_HEAD_BRANCH} --jq .name" "pr create --repo" "project item-add" "project item-edit")
    local call line previous=0
    for call in "${calls[@]}"; do
        line=$(gh_line_of "${call}")
        [ "${line}" -eq "$((previous + 1))" ] || { echo "out of order: ${call}" >&2; return 1; }
        previous="${line}"
    done
    [ "${previous}" -eq "$(wc -l < "${GH_LOG}")" ]
    [ "$(gh_call_count "api graphql")" -eq 0 ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
}

@test "pr create passes an explicit --base through without reading the repository, and writes the Workflow Status field of a board not converted yet" {
    prepare_pr_create
    write_legacy_field_list
    run_pr_create --base release/2
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_PR_URL}" ]
    issue_create_called_with "pr create --repo ${REPO} --head ${PR_HEAD_BRANCH} --base release/2 --draft --title ${PR_TITLE} --body-file BODY"
    [ "$(gh_call_count "api repos/${REPO} ")" -eq 0 ]
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_wf --single-select-option-id wf_4" "${GH_LOG}"
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "pr create fails before the create when the head branch is not pushed, the repository is not found or the default branch is the head, never naming the branch" {
    prepare_pr_create
    rm "$(api_fixture "repos/${REPO}/branches/${PR_HEAD_BRANCH}").json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the --head was not found in ${REPO}: push the branch first" ]

    write_head_branch "${PR_HEAD_BRANCH}" "feat/another"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the --head of ${REPO}" ]

    write_head_branch "${PR_HEAD_BRANCH}"
    jq -n --arg head "${PR_HEAD_BRANCH}" '{default_branch: $head}' | write_api "repos/${REPO}"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the --head is the default branch of ${REPO}" ]

    jq -n '{default_branch: "a..b"}' | write_api "repos/${REPO}"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected default branch for ${REPO}" ]

    rm "$(api_fixture "repos/${REPO}").json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]

    [ -z "${output}" ]
    assert_no_pull_request_created
}

@test "pr create reports a failed read of the repository or of the head branch as a runtime failure quoting gh, never as not found" {
    prepare_pr_create
    fail_api "repos/${REPO}/branches/${PR_HEAD_BRANCH}"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the --head of ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    fail_api "repos/${REPO}"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    assert_no_pull_request_created
}

@test "pr create percent-encodes a head branch an API path cannot hold as it is, and hands gh the name itself" {
    prepare_pr_create
    write_head_branch "feat/a%2Bb%40c" "feat/a+b@c"
    run_pr_create_replacing --head "feat/a+b@c"
    [ "${status}" -eq 0 ]
    grep -qxF "api repos/${REPO}/branches/feat/a%2Bb%40c --jq .name" "${GH_LOG}"
    issue_create_called_with "pr create --repo ${REPO} --head feat/a+b@c --base main --draft --title ${PR_TITLE} --body-file BODY"
}

@test "pr create prints the open pull request the head branch already has, creating none and changing neither its title nor its body, whatever its base or draft state" {
    prepare_pr_create
    write_pr_board_status Development
    local row
    for row in "main|true" "main|false" "release/2|true"; do
        : > "${GH_LOG}"
        write_pr_list "$(pull_request 7 feat/another main someone true false "another branch")" "$(existing_pull_request "${row%|*}" "${row#*|}")"
        run_pr_create
        [ "${status}" -eq 0 ]
        [ "${output}" = "${EXISTING_PR_URL}" ]
        [ "${stderr}" = "${PR_EXISTS_NOTE/base main/base ${row%|*}}" ]
        assert_no_pull_request_created
        [ "$(gh_call_count "pr list")" -eq 1 ]
        [ "$(gh_call_count "api repos/")" -eq 0 ]
        grep -qF "pullRequest(number:\$n)" "${GH_LOG}"
        grep -qF -- "-F n=1650 " "${GH_LOG}"
        [ "$(gh_call_count "mutation")" -eq 0 ]
    done
}

@test "pr create moves an existing pull request forward to Development and never back: absent, unset and earlier states get one write, Development and later ones none" {
    prepare_pr_create
    write_pr_list "$(existing_pull_request)"
    local state
    for state in absent unset "Not Started" Planning Approved; do
        : > "${GH_LOG}"
        write_pr_board_status "${state}"
        run_pr_create
        [ "${status}" -eq 0 ] || { echo "failed at ${state}" >&2; return 1; }
        [ "${output}" = "${EXISTING_PR_URL}" ]
        [ "${stderr}" = "${PR_EXISTS_NOTE}" ]
        assert_set_to_development "${EXISTING_PR_URL}"
        [ "$(gh_call_count "pr create --repo")" -eq 0 ]
    done

    for state in Development "AI Simplify" "AI Review" "AI Security Review" "AI Coverage" "Human Review" Complete; do
        : > "${GH_LOG}"
        write_pr_board_status "${state}"
        run_pr_create
        [ "${status}" -eq 0 ] || { echo "failed at ${state}" >&2; return 1; }
        [ "${output}" = "${EXISTING_PR_URL}" ]
        [ "${stderr}" = "${PR_EXISTS_NOTE}" ]
        assert_no_pull_request_created
    done
}

@test "pr create decides from the board listing when the direct read of an existing pull request fails" {
    prepare_pr_create
    write_pr_list "$(existing_pull_request)"
    use_fallback
    local row
    for row in "Planning|1" "AI Review|0"; do
        : > "${GH_LOG}"
        jq -n --arg state "${row%|*}" --arg repo "${REPO}" '{items: [
            {id: "PVTI_issue", content: {number: 1650, repository: $repo, type: "Issue"}, status: "Complete"},
            {id: "PVTI_target", content: {number: 1650, repository: $repo, type: "PullRequest"}, status: $state}]}' > "${GH_FIXTURES}/item-list.json"
        run_pr_create
        [ "${status}" -eq 0 ]
        [ "${output}" = "${EXISTING_PR_URL}" ]
        [[ "${stderr}" == "cfwf: warning: the direct GraphQL read failed"*$'\n'"${PR_EXISTS_NOTE}" ]]
        [ "$(gh_call_count "project item-list")" -eq 1 ]
        [ "$(gh_call_count "project item-edit")" -eq "${row#*|}" ]
    done
}

@test "pr create exits 1 naming the existing pull request when its status cannot be read, is not a workflow state, or cannot be written" {
    prepare_pr_create
    write_pr_list "$(existing_pull_request)"
    local already="cfwf: the pull request already exists: ${EXISTING_PR_URL}"

    use_fallback
    touch "${GH_FIXTURES}/item-list.fail"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not read the status of ${REPO}#1650: both the direct query and the listing of project 74 failed"$'\n'"${already}" ]]
    rm "${GH_FIXTURES}/graphql.fail" "${GH_FIXTURES}/item-list.fail"

    jq -n '{data: {repository: {pullRequest: {projectItems: {nodes: [{project: {id: "PVT_proj"}, legacy: {name: "Odd"}, status: null}]}}}}}' > "${GH_FIXTURES}/graphql-target.json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: unexpected status of ${REPO}#1650 on project 74"$'\n'"${already}" ]
    assert_no_pull_request_created

    write_pr_board_status absent
    touch "${GH_FIXTURES}/item-edit.fail"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not set the Status of ${EXISTING_PR_URL}"$'\n'"${already}" ]]
    [[ "${stderr}" != *"note:"* ]]
}

@test "pr create ignores a fork's pull request with the same head name, and refuses to choose between two of this repository's" {
    prepare_pr_create
    local fork
    fork=$(pull_request 1640 "${PR_HEAD_BRANCH}" main stranger false true "feat: from a fork")
    write_pr_list "${fork}"
    run_pr_create
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_PR_URL}" ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "pr create --repo")" -eq 1 ]

    : > "${GH_LOG}"
    write_pr_board_status Development
    write_pr_list "${fork}" "$(existing_pull_request)"
    run_pr_create
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EXISTING_PR_URL}" ]

    : > "${GH_LOG}"
    write_pr_list "$(existing_pull_request)" "$(pull_request 1660 "${PR_HEAD_BRANCH}" release/2 someone true false "feat: into another base")"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: more than one open pull request has the --head as its head branch in ${REPO}" ]
    assert_no_pull_request_created
    [ "$(gh_call_count "api graphql")" -eq 0 ]
}

@test "pr create exits 1, writing nothing, when the listing of open pull requests fails or is not what was asked for" {
    prepare_pr_create
    local answer
    # A pull request whose head only starts with the name, as if gh matched more than the exact name.
    write_pr_list "$(pull_request 1650 "${PR_HEAD_BRANCH}-2" main someone true false "feat: a longer branch")"
    touch "${GH_FIXTURES}/pr-list.ignore-head"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "${PR_LIST_UNEXPECTED}" ]
    rm "${GH_FIXTURES}/pr-list.ignore-head"

    for answer in "garbage" "1"$'\n'"1650	${PR_HEAD_BRANCH}	main	someone	draft	-	http://github.com/${REPO}/pull/1650	t" \
        "1"$'\n'"1650	${PR_HEAD_BRANCH}	main	someone	draft	-	https://github.com/${REPO}/pull/1651	t" \
        "1"$'\n'"1650	${PR_HEAD_BRANCH}	main	someone	draft	-	https://github.com/${REPO}/issues/1650	t"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/pr-list.out"
        run_pr_create
        [ "${status}" -eq 1 ]
        [ "${stderr}" = "${PR_LIST_UNEXPECTED}" ]
    done
    rm "${GH_FIXTURES}/pr-list.out"

    jq -n --arg head "${PR_HEAD_BRANCH}" --arg repo "${REPO}" '[range(1; 1002) | {number: ., title: "t", headRefName: $head, baseRefName: "main",
        isDraft: false, isCrossRepository: true, author: {login: "someone"}, url: "https://github.com/\($repo)/pull/\(.)"}]' > "${GH_FIXTURES}/pr-list.json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: ${REPO} has more than 1000 open pull requests, so none is printed" ]

    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/pr-list.fail"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not list the open pull requests of ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    [ -z "${output}" ]
    assert_no_pull_request_created
}

@test "pr create looks again when the create fails, takes the pull request that is there now as the existing one, and never creates twice" {
    prepare_pr_create
    printf 'a pull request for the branch already exists\nsecond line\n' > "${GH_FIXTURES}/pr-create.fail"
    printf '%s\n' "$(existing_pull_request)" | jq -s '.' > "${GH_FIXTURES}/pr-create.then-list.json"
    write_pr_board_status Planning
    run_pr_create
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EXISTING_PR_URL}" ]
    [ "${stderr}" = "${PR_EXISTS_NOTE}" ]
    [ "$(gh_call_count "pr create --repo")" -eq 1 ]
    [ "$(gh_call_count "pr list")" -eq 2 ]
    [ "$(gh_line_of "pr create --repo")" -lt "$(gh_line_of "api graphql")" ]
    assert_set_to_development "${EXISTING_PR_URL}"

    # One that is already past Development is left where it is.
    : > "${GH_LOG}"
    write_pr_list
    write_pr_board_status "AI Review"
    run_pr_create
    [ "${status}" -eq 0 ]
    [ "${output}" = "${EXISTING_PR_URL}" ]
    [ "$(gh_call_count "pr create --repo")" -eq 1 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "pr create exits 1 quoting gh's first line when the create fails and no pull request is there, or when the second look fails" {
    prepare_pr_create
    printf 'pull request create failed: GraphQL: No commits between main and the head\nsecond line\n' > "${GH_FIXTURES}/pr-create.fail"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not create the pull request in ${REPO}: pull request create failed: GraphQL: No commits between main and the head" ]
    [ "$(gh_call_count "pr create --repo")" -eq 1 ]
    [ "$(gh_call_count "pr list")" -eq 2 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]

    : > "${GH_LOG}"
    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/pr-create.then-list.fail"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not list the open pull requests of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    [ "$(gh_call_count "pr create --repo")" -eq 1 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "pr create exits 1 and names the new pull request on stderr when the board write is rejected, printing nothing on stdout" {
    prepare_pr_create
    local created="cfwf: the pull request was already created: ${NEW_PR_URL}"
    touch "${GH_FIXTURES}/item-edit.fail"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not set the Status of ${NEW_PR_URL}"$'\n'"${created}" ]]

    rm "${GH_FIXTURES}/item-edit.fail"
    touch "${GH_FIXTURES}/item-add.fail"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not add ${NEW_PR_URL} to project 74"$'\n'"${created}" ]]

    # A failure before the create names no pull request.
    rm "${GH_FIXTURES}/item-add.fail" "$(api_fixture "repos/${REPO}/branches/${PR_HEAD_BRANCH}").json"
    run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the --head was not found in ${REPO}: push the branch first" ]
}

@test "pr create takes the last line gh prints as the URL, from any https host or repository, and refuses anything that is not a pull request URL" {
    prepare_pr_create
    local answer url
    for answer in "https://github-proxy.example.com/credfeto/credfeto-orchestrator/pull/7" "https://github.com/credfeto/renamed-repo/pull/5" \
        "Creating draft pull request"$'\n'"https://github.com/CredFeto/Credfeto-Orchestrator/pull/1700"; do
        url="${answer##*$'\n'}"
        : > "${GH_LOG}"
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/pr-create.out"
        run_pr_create
        [ "${status}" -eq 0 ]
        [ "${output}" = "${url}" ]
        assert_set_to_development "${url}"
    done

    : > "${GH_LOG}"
    for answer in "http://github.com/credfeto/credfeto-orchestrator/pull/7" "https://github.com/credfeto/credfeto-orchestrator/issues/7" \
        "https://github.com/credfeto/pull/7" "something LEAKMARKER odd" ""; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/pr-create.out"
        run_pr_create
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the new pull request, which may have been created" ]
    done
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "pr list")" -eq 5 ]
}

@test "pr create leaves no temporary file behind, for a stdin body, a refusal, a failed run and a run that succeeds" {
    prepare_pr_create
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"

    TMPDIR="${scratch}" run_pr_create_with_body - <<< "from stdin"
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run_pr_create
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    write_leak_body "see /home/someone/work"
    TMPDIR="${scratch}" run_pr_create_with_body "${TEST_TMP}/leak.md"
    [ "${status}" -eq 8 ]
    [ -z "$(ls -A "${scratch}")" ]

    printf 'boom\n' > "${GH_FIXTURES}/pr-create.fail"
    TMPDIR="${scratch}" run_pr_create
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
}

@test "pr create fails (exit 1) when gh is not installed, after the options are checked" {
    prepare_pr_create
    pr_create_args
    # --head is judged by git, so the path holds git and nothing else.
    mkdir -p "${TEST_TMP}/git-only"
    ln -s "$(command -v git)" "${TEST_TMP}/git-only/git"
    run --separate-stderr env PATH="${TEST_TMP}/git-only" "$(command -v bash)" "${SCRIPT}" "${PR_CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]

    run --separate-stderr env PATH="${TEST_TMP}/git-only" "$(command -v bash)" "${SCRIPT}" "${PR_CREATE_ARGS[@]:0:8}"
    [ "${status}" -eq 2 ]
}

# --- pr hand-off ---------------------------------------------------------------

HAND_OFF_URL="https://github.com/credfeto/credfeto-orchestrator/pull/42"
HAND_OFF_COMMENT_URL="https://github.com/credfeto/credfeto-orchestrator/pull/42#issuecomment-4343"
HAND_OFF_NEW_SHA="2222222222222222222222222222222222222222"
HAND_OFF_TITLE="feat(cfwf): hand a pull request off with its real title"
HAND_OFF_BOARD_EDIT="project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_9"

# Writes PR 42 as the pulls endpoint gives it: state $1 (open by default), draft $2 (false by
# default), head $3 (HEAD_SHA by default), then each further argument a label name.
write_hand_off_pr() {
    local state="${1:-open}" draft="${2:-false}" sha="${3:-${HEAD_SHA}}"
    shift 3 2> /dev/null || shift "$#"
    jq -n --arg state "${state}" --argjson draft "${draft}" --arg sha "${sha}" --arg url "${HAND_OFF_URL}" --args \
        '{number: 42, state: $state, draft: $draft, html_url: $url, head: {sha: $sha}, base: {ref: "main"},
          labels: ($ARGS.positional | map({name: ., color: "ff0000"}))}' "$@" \
        | write_api "repos/${REPO}/pulls/42"
}

# PR 42, open and ready, whose head is HEAD_SHA; main requires build, which passed at COMPLETED_AT
# (12:00); the pull request was last marked ready at 11:00; the repository allows auto-merge; the
# review record posts as HAND_OFF_COMMENT_URL. Each test changes what it needs.
prepare_hand_off() {
    write_hand_off_pr open false
    jq -n --arg repo "${REPO}" '{id: 1, full_name: $repo, default_branch: "main", allow_auto_merge: true}' | write_api "repos/${REPO}"
    write_protection main build
    write_no_rulesets main
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
    write_issue_kind 42 pull 2026-10-01T08:00:00Z
    write_timeline 42 "$(timeline_event ready_for_review credfeto "" 2026-10-01T11:00:00Z)"
    printf '%s\n' "${HAND_OFF_COMMENT_URL}" > "${GH_FIXTURES}/comment.out"
    printf 'Reviewed and ready.\n' > "${TEST_TMP}/hand-off.md"
    printf 'What the pull request really holds.\n\nCloses #1755\n' > "${TEST_TMP}/description.md"
}

# Makes "gh pr ready" copy every file a test puts in pr-ready.then over the fixtures, as what
# GitHub answers changes once a pull request is marked ready (new check runs, a new head).
after_ready() {
    mkdir -p "${GH_FIXTURES}/pr-ready.then"
}

run_hand_off() {
    run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title "${HAND_OFF_TITLE}" \
        --description-file "${TEST_TMP}/description.md" --body-file "${TEST_TMP}/hand-off.md"
}

# Nothing was written: no board change, no ready, no comment and no merge request.
assert_nothing_handed_off() {
    [ "$(gh_call_count "pr edit")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
}

@test "pr hand-off on a ready pull request moves the board, records the head and enables merge-commit auto-merge, in that order" {
    prepare_hand_off
    run_hand_off
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${HAND_OFF_URL} title and description set
${HAND_OFF_URL} Human Review
${HAND_OFF_URL} ready
${HAND_OFF_COMMENT_URL}
${HAND_OFF_URL} auto-merge on" ]
    [ "$(gh_call_count "pr edit 42 --repo ${REPO} --title ${HAND_OFF_TITLE} --body-file ")" -eq 1 ]
    cmp "${TEST_TMP}/description.md" "${GH_FIXTURES}/edit-body.txt"
    # gh is given the checked copy, never the caller's file.
    [ "$(gh_call_count "--body-file ${TEST_TMP}/description.md")" -eq 0 ]
    [ "$(gh_line_of "pr edit 42")" -lt "$(gh_line_of "project item-edit")" ]
    grep -qxF "${HAND_OFF_BOARD_EDIT}" "${GH_LOG}"
    # Already ready, so it is not marked ready again.
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    grep -qxF "pr merge 42 --repo ${REPO} --auto --merge --match-head-commit ${HEAD_SHA}" "${GH_LOG}"
    [ "$(gh_call_count "--admin")" -eq 0 ]
    [ "$(gh_line_of "project item-edit")" -lt "$(gh_line_of "pr comment 42")" ]
    [ "$(gh_line_of "pr comment 42")" -lt "$(gh_line_of "pr merge 42")" ]
    [ "$(sed -n 1p "${GH_FIXTURES}/comment-body.txt")" = "### AI Review Loop: reviewed ${HEAD_SHA}" ]
    [ "$(sed -n 2p "${GH_FIXTURES}/comment-body.txt")" = "" ]
    [ "$(sed -n 3p "${GH_FIXTURES}/comment-body.txt")" = "Reviewed and ready." ]
}

@test "pr hand-off marks a draft ready after the board and before the record, then enables auto-merge at once although the checks predate the ready time (#1798)" {
    prepare_hand_off
    write_hand_off_pr open true
    write_timeline 42 "$(timeline_event ready_for_review credfeto "" 2026-10-01T13:00:00Z)"
    run_hand_off
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${HAND_OFF_URL} title and description set
${HAND_OFF_URL} Human Review
${HAND_OFF_URL} ready
${HAND_OFF_COMMENT_URL}
${HAND_OFF_URL} auto-merge on" ]
    grep -qxF "pr ready 42 --repo ${REPO}" "${GH_LOG}"
    [ "$(gh_line_of "project item-edit")" -lt "$(gh_line_of "pr ready 42")" ]
    [ "$(gh_line_of "pr ready 42")" -lt "$(gh_line_of "pr comment 42")" ]
    [ "$(gh_line_of "pr comment 42")" -lt "$(gh_line_of "pr merge 42")" ]
    grep -qxF "pr merge 42 --repo ${REPO} --auto --merge --match-head-commit ${HEAD_SHA}" "${GH_LOG}"
    [ "$(gh_call_count "--admin")" -eq 0 ]
}

@test "pr hand-off enables auto-merge (exit 0) when a required check is pending, or failed, after the pull request was marked ready, since GitHub's auto-merge waits for it (#1798)" {
    local conclusion
    for conclusion in "" failure; do
        prepare_hand_off
        write_hand_off_pr open true
        after_ready
        check_run build "${conclusion}" 12 > "${TEST_TMP}/run.json"
        printf '%s\n' "$(cat "${TEST_TMP}/run.json")" | jq -s '{total_count: length, check_runs: .}' \
            > "${GH_FIXTURES}/pr-ready.then/api-repos_credfeto_credfeto-orchestrator_commits_${HEAD_SHA}_check-runs.json"
        : > "${GH_LOG}"
        run_hand_off
        [ "${status}" -eq 0 ]
        [ "${output##*$'\n'}" = "${HAND_OFF_URL} auto-merge on" ]
        [ "$(gh_call_count "pr merge 42 --repo ${REPO} --auto --merge --match-head-commit ${HEAD_SHA}")" -eq 1 ]
        rm -rf "${GH_FIXTURES}/pr-ready.then"
    done
}

# Makes main, the base of PR 42, an unprotected branch with no rules: it requires no check and no
# review. The checks on the head are still judged before the hand-off (every check, since none is
# required), so build passing lets it through.
write_ungated_base() {
    write_branch main
    write_no_rulesets main
}

@test "pr hand-off leaves auto-merge off, and says so, on a base branch that requires no check and no review (#1798)" {
    prepare_hand_off
    write_ungated_base
    run_hand_off
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${HAND_OFF_URL} title and description set
${HAND_OFF_URL} Human Review
${HAND_OFF_URL} ready
${HAND_OFF_COMMENT_URL}
${HAND_OFF_URL} auto-merge not armed: the base branch requires no check and no review, so auto-merge would merge it at once; it is left ready for a human" ]
    [ "$(gh_call_count "pr comment 42")" -eq 1 ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]

    # A plan without rulesets has none, so the same unprotected branch is still ungated.
    prepare_hand_off
    write_branch main
    fail_api "repos/${REPO}/rules/branches/main" "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)"
    : > "${GH_LOG}"
    run_hand_off
    [ "${status}" -eq 0 ]
    [[ "${output##*$'\n'}" == "${HAND_OFF_URL} auto-merge not armed: "* ]]
    [ "$(gh_call_count "pr merge")" -eq 0 ]

    # A pull_request rule that asks for no approval and no code owner requires no review.
    prepare_hand_off
    write_branch main
    jq -n '[{type: "pull_request", parameters: {required_approving_review_count: 0, require_code_owner_review: false}},
        {type: "required_status_checks", parameters: {required_status_checks: []}}, {type: "deletion"}]' \
        | write_api "repos/${REPO}/rules/branches/main"
    : > "${GH_LOG}"
    run_hand_off
    [ "${status}" -eq 0 ]
    [[ "${output##*$'\n'}" == "${HAND_OFF_URL} auto-merge not armed: "* ]]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
}

@test "pr hand-off enables auto-merge on an unprotected base branch whose rulesets require a review, a code owner or a check (#1798)" {
    local rules
    for rules in '[{type: "pull_request", parameters: {required_approving_review_count: 1}}]' \
        '[{type: "pull_request", parameters: {required_approving_review_count: 0, require_code_owner_review: true}}]' \
        '[{type: "required_status_checks", parameters: {required_status_checks: [{context: "build"}]}}]'; do
        prepare_hand_off
        write_branch main
        jq -n "${rules}" | write_api "repos/${REPO}/rules/branches/main"
        : > "${GH_LOG}"
        run_hand_off
        [ "${status}" -eq 0 ]
        [ "${output##*$'\n'}" = "${HAND_OFF_URL} auto-merge on" ]
        [ "$(gh_call_count "pr merge 42 --repo ${REPO} --auto --merge --match-head-commit ${HEAD_SHA}")" -eq 1 ]
    done
}

@test "pr hand-off enables auto-merge when whether the base requires a review is unknown: a protected branch without required checks, or a branch or rules read that fails after ready (#1798)" {
    local case_
    # Classic protection's review rule needs admin rights to read, so a protected branch is unknown.
    prepare_hand_off
    write_protection main
    write_no_rulesets main
    run_hand_off
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "${HAND_OFF_URL} auto-merge on" ]

    # The reads before the hand-off see an ungated base; the ones after ready fail.
    for case_ in "branches/main" "rules/branches/main"; do
        prepare_hand_off
        write_hand_off_pr open true
        write_ungated_base
        after_ready
        printf '%s\n' "gh: Bad Gateway (HTTP 502)" > "${GH_FIXTURES}/pr-ready.then/$(basename "$(api_fixture "repos/${REPO}/${case_}")").fail"
        : > "${GH_LOG}"
        run_hand_off
        [ "${status}" -eq 0 ]
        [ "${output##*$'\n'}" = "${HAND_OFF_URL} auto-merge on" ]
        [ "$(gh_call_count "pr merge")" -eq 1 ]
        rm -rf "${GH_FIXTURES}/pr-ready.then" "$(api_fixture "repos/${REPO}/${case_}").fail"
    done
}

@test "pr hand-off stops before auto-merge, naming the steps done, when the head changes after it was reviewed" {
    prepare_hand_off
    write_hand_off_pr open true
    after_ready
    cp "$(api_fixture "repos/${REPO}/pulls/42").json" "${TEST_TMP}/pr.json"
    jq --arg sha "${HAND_OFF_NEW_SHA}" '.head.sha = $sha' "${TEST_TMP}/pr.json" \
        > "${GH_FIXTURES}/pr-ready.then/api-repos_credfeto_credfeto-orchestrator_pulls_42.json"
    jq '.' "$(api_fixture "repos/${REPO}/commits/${HEAD_SHA}/check-runs").json" \
        > "${GH_FIXTURES}/pr-ready.then/api-repos_credfeto_credfeto-orchestrator_commits_${HAND_OFF_NEW_SHA}_check-runs.json"
    jq '.' "$(api_fixture "repos/${REPO}/commits/${HEAD_SHA}/status").json" \
        > "${GH_FIXTURES}/pr-ready.then/api-repos_credfeto_credfeto-orchestrator_commits_${HAND_OFF_NEW_SHA}_status.json"
    write_timeline 42 "$(timeline_event ready_for_review credfeto "" 2026-10-01T11:00:00Z)"
    run_hand_off
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"cfwf: the head of ${REPO}#42 changed after it was reviewed, so auto-merge was not enabled"* ]]
    [[ "${stderr}" == *"cfwf: hand-off steps done before the failure: title and description, board Human Review, ready, review record" ]]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
}

@test "pr hand-off refuses (exit 8, nothing written) a pull request that is closed, Blocked or On Hold" {
    local case_ expected
    for case_ in "closed|the pull request is not open" "Blocked|the pull request is Blocked" "On Hold|the pull request is On Hold" "on-hold|the pull request is On Hold" "blocked|the pull request is Blocked"; do
        prepare_hand_off
        if [ "${case_%%|*}" = closed ]; then
            write_hand_off_pr closed false
        else
            write_hand_off_pr open false "${HEAD_SHA}" Medium "${case_%%|*}"
        fi
        expected="${case_#*|}"
        : > "${GH_LOG}"
        run_hand_off
        [ "${status}" -eq 8 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: hand-off refused: ${expected}" ]
        assert_nothing_handed_off
    done
}

@test "pr hand-off refuses (exit 8, nothing written) when a required check failed, is pending, or the head has no checks" {
    local case_
    for case_ in "failure|a required check failed" "|a required check is still pending" "none|the head has no checks yet"; do
        prepare_hand_off
        case "${case_%%|*}" in
            none)
                write_no_rulesets main
                write_branch main
                write_check_runs "${HEAD_SHA}"
                ;;
            *) write_check_runs "${HEAD_SHA}" "$(check_run build "${case_%%|*}" 11)" ;;
        esac
        : > "${GH_LOG}"
        run_hand_off
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: hand-off refused: ${case_#*|}" ]
        assert_nothing_handed_off
    done
}

@test "pr hand-off refuses (exit 8) a body that leaks or carries a plan-approval keyword, before any gh call" {
    prepare_hand_off
    printf 'see /home/someone/secret.txt\n' > "${TEST_TMP}/hand-off.md"
    : > "${GH_LOG}"
    run_hand_off
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    assert_nothing_handed_off
    [ "$(gh_call_count "pulls/42")" -eq 0 ]

    printf '  Approved\n' > "${TEST_TMP}/hand-off.md"
    : > "${GH_LOG}"
    run_hand_off
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: approval keyword (line 1)" ]
    assert_nothing_handed_off
    [ "$(gh_call_count "pulls/42")" -eq 0 ]
}

@test "pr hand-off on a repository without auto-merge leaves the pull request ready for a human and exits 0 without a merge request" {
    prepare_hand_off
    jq -n --arg repo "${REPO}" '{id: 1, full_name: $repo, default_branch: "main", allow_auto_merge: false}' | write_api "repos/${REPO}"
    run_hand_off
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "${HAND_OFF_URL} auto-merge unavailable: the repository does not allow auto-merge, so the pull request is left ready for a human" ]
    [ "$(gh_call_count "pr comment 42")" -eq 1 ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
}

@test "pr hand-off exits 9 for a pull request that does not exist, writing nothing" {
    prepare_hand_off
    rm "$(api_fixture "repos/${REPO}/pulls/42").json"
    run_hand_off
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    assert_nothing_handed_off
}

@test "pr hand-off rejects usage errors (exit 2) without calling gh" {
    local args td
    printf 'text\n' > "${TEST_TMP}/hand-off.md"
    printf 'description\n' > "${TEST_TMP}/description.md"
    td="--title fix:x --description-file ${TEST_TMP}/description.md"
    for args in "--repo ${REPO} ${td}" "--repo ${REPO} ${td} --body-file ${TEST_TMP}/hand-off.md" \
        "--pr 42 ${td} --body-file ${TEST_TMP}/hand-off.md" "--repo ${REPO} --pr 0 ${td} --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 ${td} --body-file ${TEST_TMP}/hand-off.md --admin" \
        "--repo ${REPO} --pr 42 --pr 43 ${td} --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 --description-file ${TEST_TMP}/description.md --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 --title fix:x --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 --title fix:x --description text --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 --title fix:x --body text --description-file ${TEST_TMP}/description.md" \
        "--repo ${REPO} --pr 42 ${td} --description-file ${TEST_TMP}/description.md --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 --title fix:x --title fix:y --description-file ${TEST_TMP}/description.md --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 --title placeholder --description-file ${TEST_TMP}/description.md --body-file ${TEST_TMP}/hand-off.md" \
        "--repo ${REPO} --pr 42 --title fix:x --description-file - --body-file -"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr hand-off ${args}
        [ "${status}" -eq 2 ]
        [ ! -s "${GH_LOG}" ]
    done
    run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title "" \
        --description-file "${TEST_TMP}/description.md" --body-file "${TEST_TMP}/hand-off.md"
    [ "${status}" -eq 2 ]
    [ ! -s "${GH_LOG}" ]
    run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title fix:x \
        --description-file - --body-file -
    [[ "${stderr}" == "cfwf: --description-file and --body-file cannot both read stdin (-)"* ]]
}

@test "pr hand-off refuses a description that is missing, empty, leaks or carries a plan-approval keyword, before any gh call" {
    prepare_hand_off
    : > "${TEST_TMP}/description.md"
    : > "${GH_LOG}"
    run_hand_off
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the description is empty" ]
    assert_nothing_handed_off
    [ "$(gh_call_count "pulls/42")" -eq 0 ]

    printf ' \n\t\n' > "${TEST_TMP}/description.md"
    run_hand_off
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the description is empty" ]

    rm "${TEST_TMP}/description.md"
    run_hand_off
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: cannot read the --description-file" ]

    printf 'see /home/someone/secret.txt\n' > "${TEST_TMP}/description.md"
    : > "${GH_LOG}"
    run_hand_off
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    assert_nothing_handed_off
    [ "$(gh_call_count "pulls/42")" -eq 0 ]

    printf '  Approved\n' > "${TEST_TMP}/description.md"
    : > "${GH_LOG}"
    run_hand_off
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: approval keyword (line 1)" ]
    assert_nothing_handed_off
    [ "$(gh_call_count "pulls/42")" -eq 0 ]
}

@test "pr hand-off reads the description from stdin for --description-file -" {
    prepare_hand_off
    run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title "${HAND_OFF_TITLE}" \
        --description-file - --body-file "${TEST_TMP}/hand-off.md" <<< "A description from stdin"
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/edit-body.txt")" = "A description from stdin" ]
    [ "$(sed -n 3p "${GH_FIXTURES}/comment-body.txt")" = "Reviewed and ready." ]
}

@test "pr hand-off stops (exit 1) with nothing else written when setting the title and description fails" {
    prepare_hand_off
    printf 'boom\n' > "${GH_FIXTURES}/pr-edit.fail"
    run_hand_off
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: could not set the title and description of ${REPO}#42: "* ]]
    [[ "${stderr}" != *"steps done"* ]]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
}

@test "pr hand-off help, from help pr hand-off, pr hand-off --help and -h, describes the order and that auto-merge is never deferred; help pr and the general help point to it; none calls gh" {
    local invocation
    for invocation in "help pr hand-off" "pr hand-off --help" "pr hand-off -h"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr hand-off --repo <owner/repo> --pr <n> --title <title> --description-file <file|->"* ]]
        [[ "${output}" == *"There is no --description."* ]]
        [[ "${output}" == *"### AI Review Loop: reviewed <head SHA>"* ]]
        [[ "${output}" == *"[--body-file <file>]"*"--description-file - <<'EOF'"* ]]
        [[ "${output}" == *"Auto-merge is always enabled once the pull request is ready"* ]]
        [[ "${output}" == *'"<url> auto-merge not'$'\n''armed: <reason>"'* ]]
        [[ "${output}" != *"deferred"* ]]
    done
    run "${SCRIPT}" help pr
    [[ "${output}" == *"Run 'cfwf pr hand-off --help' for pr hand-off"* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *"  pr hand-off              Hand a PR to human review"*"then auto-merge (exit 8 refused)"$'\n'* ]]
    [ ! -s "${GH_LOG}" ]
}

@test "pr hand-off without --body-file is one call: the description on stdin and a review record of its own first line only (#1775)" {
    prepare_hand_off
    run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title "${HAND_OFF_TITLE}" \
        --description-file - <<< "A description from stdin"
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/edit-body.txt")" = "A description from stdin" ]
    [ "$(cat "${GH_FIXTURES}/comment-body.txt")" = "### AI Review Loop: reviewed ${HEAD_SHA}" ]
    [ "$(wc -l < "${GH_FIXTURES}/comment-body.txt")" -eq 1 ]
    [ "${output##*$'\n'}" = "${HAND_OFF_URL} auto-merge on" ]
}

@test "pr hand-off still refuses an empty, leaking or approving description when --body-file is omitted, writing nothing (#1775)" {
    prepare_hand_off
    : > "${GH_LOG}"
    run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title "${HAND_OFF_TITLE}" \
        --description-file - <<< "   "
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"description is empty"* ]]
    [ ! -s "${GH_LOG}" ]
    for text in 'see /home/someone/secret.txt' '  Approved'; do
        : > "${GH_LOG}"
        run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title "${HAND_OFF_TITLE}" \
            --description-file - <<< "${text}"
        [ "${status}" -eq 8 ]
        assert_nothing_handed_off
        [ "$(gh_call_count "pulls/42")" -eq 0 ]
    done
}

@test "pr hand-off reads the review record from stdin for --body-file - when the description is a file (#1775)" {
    prepare_hand_off
    run --separate-stderr "${SCRIPT}" pr hand-off --repo "${REPO}" --pr 42 --title "${HAND_OFF_TITLE}" \
        --description-file "${TEST_TMP}/description.md" --body-file - <<< "Record from stdin"
    [ "${status}" -eq 0 ]
    [ "$(sed -n 3p "${GH_FIXTURES}/comment-body.txt")" = "Record from stdin" ]
}

# --- pr finalise-dependency ----------------------------------------------------

DEPENDENCY_BRANCH_NAME="depends/update-packages"

# Writes PR 42 as the pulls endpoint gives it, for pr finalise-dependency: state $1 (open), draft $2
# (false), head branch $3 (DEPENDENCY_BRANCH_NAME), author $4 (dependabot[bot]), author type $5
# (Bot), head repository $6 (REPO), then each further argument a label name.
write_dependency_pr() {
    local state="${1:-open}" draft="${2:-false}" branch="${3:-${DEPENDENCY_BRANCH_NAME}}" author="${4:-dependabot[bot]}" type="${5:-Bot}" head_repo="${6:-${REPO}}"
    shift 6 2> /dev/null || shift "$#"
    jq -n --arg state "${state}" --argjson draft "${draft}" --arg sha "${HEAD_SHA}" --arg url "${HAND_OFF_URL}" \
        --arg branch "${branch}" --arg author "${author}" --arg type "${type}" --arg head_repo "${head_repo}" --arg repo "${REPO}" --args \
        '{number: 42, state: $state, draft: $draft, html_url: $url, user: {login: $author, type: $type},
          head: {sha: $sha, ref: $branch, repo: (if $head_repo == "-" then null else {full_name: $head_repo} end)},
          base: {ref: "main", repo: {full_name: $repo}},
          labels: ($ARGS.positional | map({name: ., color: "ff0000"}))}' "$@" \
        | write_api "repos/${REPO}/pulls/42"
}

# PR 42 as prepare_hand_off sets it up, but a dependency update by dependabot[bot] on a depends/ branch.
prepare_dependency() {
    prepare_hand_off
    write_dependency_pr
}

run_finalise() {
    run --separate-stderr "${SCRIPT}" pr finalise-dependency --repo "${REPO}" --pr 42
}

# Nothing was ever written by finalise-dependency, nor anything hand-off alone writes.
assert_never_hand_off_writes() {
    [ "$(gh_call_count "pr edit")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
}

@test "pr finalise-dependency on a ready dependency PR enables merge-commit auto-merge and touches nothing else (#1771)" {
    prepare_dependency
    run_finalise
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${HAND_OFF_URL} ready
${HAND_OFF_URL} auto-merge on" ]
    grep -qxF "pr merge 42 --repo ${REPO} --auto --merge --match-head-commit ${HEAD_SHA}" "${GH_LOG}"
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    [ "$(gh_call_count "--admin")" -eq 0 ]
    assert_never_hand_off_writes
}

@test "pr finalise-dependency marks a draft ready, then enables auto-merge at once although the checks predate the ready time (#1771, #1798)" {
    prepare_dependency
    write_dependency_pr open true
    write_timeline 42 "$(timeline_event ready_for_review credfeto "" 2026-10-01T13:00:00Z)"
    run_finalise
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${HAND_OFF_URL} ready
${HAND_OFF_URL} auto-merge on" ]
    grep -qxF "pr ready 42 --repo ${REPO}" "${GH_LOG}"
    [ "$(gh_line_of "pr ready 42")" -lt "$(gh_line_of "pr merge 42")" ]
    grep -qxF "pr merge 42 --repo ${REPO} --auto --merge --match-head-commit ${HEAD_SHA}" "${GH_LOG}"
    assert_never_hand_off_writes
}

@test "pr finalise-dependency leaves auto-merge off, and says so, on a base branch that requires no check and no review (#1798)" {
    prepare_dependency
    write_ungated_base
    run_finalise
    [ "${status}" -eq 0 ]
    [ "${output}" = "${HAND_OFF_URL} ready
${HAND_OFF_URL} auto-merge not armed: the base branch requires no check and no review, so auto-merge would merge it at once; it is left ready for a human" ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
    assert_never_hand_off_writes
}

@test "pr finalise-dependency accepts a dependabot/ branch and a PR opened by the agent's PR creator (#1771)" {
    prepare_dependency
    write_dependency_pr open false "dependabot/nuget/foo-1.2.3"
    run_finalise
    [ "${status}" -eq 0 ]
    prepare_dependency
    write_dependency_pr open false "${DEPENDENCY_BRANCH_NAME}" prpixie User
    : > "${GH_LOG}"
    run_finalise
    [ "${status}" -eq 0 ]
    grep -qxF "pr merge 42 --repo ${REPO} --auto --merge --match-head-commit ${HEAD_SHA}" "${GH_LOG}"
}

@test "pr finalise-dependency refuses (exit 8, nothing written) a PR that is not a bot's dependency update (#1771)" {
    local case_ args expected
    for case_ in "open false feat/123-x dependabot[bot] Bot ${REPO}|the head branch is not a dependency-update branch (depends/ or dependabot/)" \
        "open false ${DEPENDENCY_BRANCH_NAME} dependabot[bot] Bot someone/fork|the head branch is not in the repository itself" \
        "open false ${DEPENDENCY_BRANCH_NAME} dependabot[bot] Bot -|the head branch is not in the repository itself" \
        "open false ${DEPENDENCY_BRANCH_NAME} someone User ${REPO}|the pull request was not opened by a bot" \
        "closed false ${DEPENDENCY_BRANCH_NAME} dependabot[bot] Bot ${REPO}|the pull request is not open"; do
        prepare_dependency
        args="${case_%%|*}"
        expected="${case_#*|}"
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        write_dependency_pr ${args}
        : > "${GH_LOG}"
        run_finalise
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: finalise-dependency refused: ${expected}" ]
        assert_nothing_handed_off
    done
}

@test "pr finalise-dependency refuses (exit 8, nothing written) a Blocked or On Hold PR, or one whose checks failed, are pending or are missing (#1771)" {
    local label
    for label in Blocked "On Hold"; do
        prepare_dependency
        write_dependency_pr open false "${DEPENDENCY_BRANCH_NAME}" "dependabot[bot]" Bot "${REPO}" "${label}"
        : > "${GH_LOG}"
        run_finalise
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: finalise-dependency refused: the pull request is ${label}" ]
        assert_nothing_handed_off
    done
    local case_
    for case_ in "failure|a required check failed" "|a required check is still pending"; do
        prepare_dependency
        write_check_runs "${HEAD_SHA}" "$(check_run build "${case_%%|*}" 11)"
        : > "${GH_LOG}"
        run_finalise
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: finalise-dependency refused: ${case_#*|}" ]
        assert_nothing_handed_off
    done
}

@test "pr finalise-dependency on a repository without auto-merge leaves the PR ready and exits 0 (#1771)" {
    prepare_dependency
    jq -n --arg repo "${REPO}" '{id: 1, full_name: $repo, default_branch: "main", allow_auto_merge: false}' | write_api "repos/${REPO}"
    run_finalise
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "${HAND_OFF_URL} auto-merge unavailable: the repository does not allow auto-merge, so the pull request is left ready for a human" ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
}

@test "pr finalise-dependency exits 9 for a pull request that does not exist, writing nothing (#1771)" {
    prepare_dependency
    rm "$(api_fixture "repos/${REPO}/pulls/42").json"
    run_finalise
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    assert_nothing_handed_off
}

@test "pr finalise-dependency rejects usage errors (exit 2) without calling gh (#1771)" {
    local args
    printf 'text\n' > "${TEST_TMP}/body.md"
    for args in "--repo ${REPO}" "--pr 42" "--repo ${REPO} --pr 0" "--repo ${REPO} --pr 42 --admin" \
        "--repo ${REPO} --pr 42 --pr 43" "--repo ${REPO} --pr 42 --body-file ${TEST_TMP}/body.md" \
        "--repo ${REPO} --pr 42 --title fix:x" "--repo ${REPO} --pr 42 --squash"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr finalise-dependency ${args}
        [ "${status}" -eq 2 ]
        [ ! -s "${GH_LOG}" ]
    done
}

@test "pr finalise-dependency help, from help pr finalise-dependency and --help, describes the rules and that auto-merge is never deferred; help pr and the general help point to it; none calls gh (#1771)" {
    local invocation
    for invocation in "help pr finalise-dependency" "pr finalise-dependency --help" "pr finalise-dependency -h"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr finalise-dependency --repo <owner/repo> --pr <n>"* ]]
        [[ "${output}" == *"never changes"*"the title, the description or the Workflow board"* ]]
        [[ "${output}" == *"Auto-merge is enabled as 'cfwf pr hand-off' enables it: always"* ]]
        [[ "${output}" != *"deferred"* ]]
    done
    run "${SCRIPT}" help pr
    [[ "${output}" == *"Run 'cfwf pr finalise-dependency --help' for pr finalise-dependency"* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *"  pr finalise-dependency   Mark a bot dependency-update PR ready"*"nothing else (exit 8 refused)"$'\n'* ]]
    [ ! -s "${GH_LOG}" ]
}

# --- pr take-back --------------------------------------------------------------

TAKE_BACK_BOARD_EDIT="project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_4"

# Writes PR 42 as the pulls endpoint gives it: state $1 (open by default), draft $2 (false by
# default) and auto-merge $3 (true, on, by default).
write_take_back_pr() {
    local state="${1:-open}" draft="${2:-false}" auto="${3:-true}"
    jq -n --arg state "${state}" --argjson draft "${draft}" --argjson auto "${auto}" --arg sha "${HEAD_SHA}" --arg url "${HAND_OFF_URL}" \
        '{number: 42, state: $state, draft: $draft, html_url: $url, head: {sha: $sha}, base: {ref: "main"}, labels: [],
          auto_merge: (if $auto then {merge_method: "merge", enabled_by: {login: "credfeto"}} else null end)}' \
        | write_api "repos/${REPO}/pulls/42"
}

# PR 42, open, ready for review and with auto-merge on; the comment posts as HAND_OFF_COMMENT_URL.
prepare_take_back() {
    write_take_back_pr open false true
    printf '%s\n' "${HAND_OFF_COMMENT_URL}" > "${GH_FIXTURES}/comment.out"
    printf 'Taking this back to add the review fixes.\n' > "${TEST_TMP}/take-back.md"
}

run_take_back() {
    run --separate-stderr "${SCRIPT}" pr take-back --repo "${REPO}" --pr 42 --body-file "${TEST_TMP}/take-back.md"
}

# Nothing was written: no merge request, no draft conversion, no board change and no comment.
assert_nothing_taken_back() {
    [ "$(gh_call_count "pr merge")" -eq 0 ]
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
}

@test "pr take-back turns auto-merge off, converts to draft, moves the board to Development and comments, in that order" {
    prepare_take_back
    run_take_back
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${HAND_OFF_URL} auto-merge off
${HAND_OFF_URL} draft
${HAND_OFF_URL} Development
${HAND_OFF_COMMENT_URL}" ]
    grep -qxF "pr merge 42 --repo ${REPO} --disable-auto" "${GH_LOG}"
    grep -qxF "pr ready 42 --repo ${REPO} --undo" "${GH_LOG}"
    grep -qxF "${TAKE_BACK_BOARD_EDIT}" "${GH_LOG}"
    [ "$(gh_line_of "pr merge 42")" -lt "$(gh_line_of "pr ready 42")" ]
    [ "$(gh_line_of "pr ready 42")" -lt "$(gh_line_of "project item-edit")" ]
    [ "$(gh_line_of "project item-edit")" -lt "$(gh_line_of "pr comment 42")" ]
    [ "$(cat "${GH_FIXTURES}/comment-body.txt")" = "Taking this back to add the review fixes." ]
    [ "$(gh_call_count "--admin")" -eq 0 ]
    [ "$(gh_call_count "--auto ")" -eq 0 ]
}

@test "pr take-back skips the steps already done on a draft with auto-merge off, but still moves the board and comments" {
    prepare_take_back
    write_take_back_pr open true false
    run_take_back
    [ "${status}" -eq 0 ]
    [ "${output}" = "${HAND_OFF_URL} auto-merge off
${HAND_OFF_URL} draft
${HAND_OFF_URL} Development
${HAND_OFF_COMMENT_URL}" ]
    [ "$(gh_call_count "pr merge")" -eq 0 ]
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    grep -qxF "${TAKE_BACK_BOARD_EDIT}" "${GH_LOG}"
    [ "$(gh_call_count "pr comment 42")" -eq 1 ]
}

@test "pr take-back stops before converting to a draft when turning auto-merge off fails" {
    prepare_take_back
    printf 'GraphQL: something went wrong\n' > "${GH_FIXTURES}/pr-merge.fail"
    run_take_back
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: could not turn auto-merge off on ${REPO}#42, so it was not converted to a draft"* ]]
    [[ "${stderr}" != *"steps done"* ]]
    [ "$(gh_call_count "pr ready")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
    [ "$(gh_call_count "pr comment")" -eq 0 ]
}

@test "pr take-back names the steps done when a later step fails" {
    prepare_take_back
    touch "${GH_FIXTURES}/comment.fail"
    run_take_back
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"cfwf: could not post the comment on ${REPO}#42"* ]]
    [[ "${stderr}" == *"cfwf: take-back steps done before the failure: auto-merge off, draft, board Development" ]]
}

@test "pr take-back refuses (exit 8, nothing written) a pull request that is not open" {
    prepare_take_back
    write_take_back_pr closed false true
    run_take_back
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: take-back refused: the pull request is not open" ]
    assert_nothing_taken_back
}

@test "pr take-back refuses (exit 8) a body that leaks or carries a plan-approval keyword, before any gh call" {
    prepare_take_back
    printf 'see /home/someone/secret.txt\n' > "${TEST_TMP}/take-back.md"
    : > "${GH_LOG}"
    run_take_back
    [ "${status}" -eq 8 ]
    [[ "${stderr}" == "cfwf: body refused: "* ]]
    assert_nothing_taken_back
    [ "$(gh_call_count "pulls/42")" -eq 0 ]

    printf '  Approved\n' > "${TEST_TMP}/take-back.md"
    : > "${GH_LOG}"
    run_take_back
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: approval keyword (line 1)" ]
    assert_nothing_taken_back
    [ "$(gh_call_count "pulls/42")" -eq 0 ]
}

@test "pr take-back reads the body from stdin with --body-file -" {
    prepare_take_back
    run --separate-stderr "${SCRIPT}" pr take-back --repo "${REPO}" --pr 42 --body-file - <<< "Back to development."
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/comment-body.txt")" = "Back to development." ]
}

@test "pr take-back exits 9 for a pull request that does not exist, writing nothing" {
    prepare_take_back
    jq -n --arg repo "${REPO}" '{id: 1, full_name: $repo, default_branch: "main"}' | write_api "repos/${REPO}"
    rm "$(api_fixture "repos/${REPO}/pulls/42").json"
    run_take_back
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#42 was not found" ]
    assert_nothing_taken_back
}

@test "pr take-back rejects usage errors (exit 2) without calling gh" {
    local args
    printf 'text\n' > "${TEST_TMP}/take-back.md"
    for args in "--repo ${REPO} --pr 42" "--repo ${REPO} --body-file ${TEST_TMP}/take-back.md" \
        "--pr 42 --body-file ${TEST_TMP}/take-back.md" "--repo ${REPO} --pr 0 --body-file ${TEST_TMP}/take-back.md" \
        "--repo ${REPO} --pr 42 --body-file ${TEST_TMP}/take-back.md --admin" \
        "--repo ${REPO} --pr 42 --body-file ${TEST_TMP}/take-back.md --body text" \
        "--repo ${REPO} --pr 42 --pr 43 --body-file ${TEST_TMP}/take-back.md"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr take-back ${args}
        [ "${status}" -eq 2 ]
        [ ! -s "${GH_LOG}" ]
    done
}

@test "pr take-back help, from help pr take-back, pr take-back --help and -h, describes the order; help pr and the general help point to it; none calls gh" {
    local invocation
    for invocation in "help pr take-back" "pr take-back --help" "pr take-back -h"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf pr take-back --repo <owner/repo> --pr <n> --body-file <file|->"* ]]
        [[ "${output}" == *"turns auto-merge off, converts it to"* ]]
        [[ "${output}" == *"8 refused, nothing"* ]]
    done
    run "${SCRIPT}" help pr
    [[ "${output}" == *"Run 'cfwf pr take-back --help' for pr take-back"* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *"  pr take-back             Take a PR back from human review"* ]]
    [ ! -s "${GH_LOG}" ]
}
