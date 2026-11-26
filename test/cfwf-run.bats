#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# Assigned in cfwf_helper.bash. Declared here, which keeps the value, because shellcheck does not
# follow bats `load` and would otherwise read REPO as a misspelling.
declare -g REPO

# --- run rerun -------------------------------------------------------------------
# Writes the run $1 as the REST API gives it, with fields the run read does not ask for: its status, its
# conclusion ("" for none, which GitHub gives as null), its head commit, its head branch ("" for
# none, null too) and its attempt, which is JSON so a test can give one that is not a number. $7 is
# the id answered with, when that is not $1.
write_run() {
    jq -n --argjson id "${7:-$1}" --arg status "$2" --arg conclusion "$3" --arg sha "$4" --arg branch "$5" --argjson attempt "$6" \
        '{id: $id, name: "build", event: "pull_request", status: $status,
          conclusion: (if $conclusion == "" then null else $conclusion end), head_sha: $sha,
          head_branch: (if $branch == "" then null else $branch end), run_attempt: $attempt}' \
        | write_api "repos/${REPO}/actions/runs/$1"
}

# Writes the answer to the read of the repository itself, with the default branch $1 (main).
write_run_repository() {
    jq -n --arg repo "${REPO}" --arg branch "${1:-main}" '{id: 1, full_name: $repo, default_branch: $branch}' | write_api "repos/${REPO}"
}

# The run 123 with the attempt $1 (1) and the status $2 (completed, with a failure), whose head is
# RUN_SHA on feat/x: the head of the open pull request 7, beside the pull request 8 on another branch
# with the same head. main is the default branch.
prepare_run_rerun() {
    local status="${2:-completed}" conclusion=failure
    [ "${status}" = completed ] || conclusion=""
    write_run 123 "${status}" "${conclusion}" "${RUN_SHA}" feat/x "${1:-1}"
    write_run_repository
    write_pr_list "$(pull_request 7 feat/x main someone false false "the change" "${RUN_SHA}")" \
        "$(pull_request 8 feat/y main someone false false "another change" "${RUN_SHA}")"
}

# Writes $1 open pull requests numbered from 1, all on feat/x and from forks, where only the one
# numbered $2 has RUN_SHA as its head.
write_branch_pr_list() {
    jq -n --argjson count "$1" --argjson match "$2" --arg sha "${RUN_SHA}" --arg moved "${MOVED_SHA}" --arg repo "${REPO}" \
        '[range(1; $count + 1) | {number: ., title: "change \(.)", headRefName: "feat/x", baseRefName: "main", isDraft: false,
          isCrossRepository: true, author: {login: "someone", is_bot: false}, url: "https://github.com/\($repo)/pull/\(.)",
          headRefOid: (if . == $match then $sha else $moved end)}]' > "${GH_FIXTURES}/pr-list.json"
}

run_run_rerun() {
    run --separate-stderr "${SCRIPT}" run rerun --repo "${REPO}" "$@"
}

# Succeeds when gh was never asked to rerun anything.
assert_no_rerun() {
    [ "$(gh_call_count "run rerun ")" -eq 0 ]
}

# Succeeds when a run was refused under the rule $1 and nothing was written: exit 8, nothing on
# stdout and the rule alone on stderr, given as the run's status, stdout and stderr ($2 to $4) so the
# helper never reads bats' run globals.
assert_rerun_refused() {
    [ "$2" -eq 8 ] || { echo "status $2 for $1" >&2; return 1; }
    [ -z "$3" ]
    [ "$4" = "cfwf: rerun refused: $1" ]
    assert_no_rerun
}

# Succeeds when a run answer was refused as unexpected: exit 1, nothing on stdout, the message on
# stderr and nothing written, given as the run's status, stdout and stderr ($2 to $4); $1 names the
# case for the failure message.
assert_unexpected_run() {
    [ "$2" -eq 1 ] || { echo "accepted: $1 ($2)" >&2; return 1; }
    [ -z "$3" ]
    [ "$4" = "${RUN_UNEXPECTED}" ] || { echo "$1: $4" >&2; return 1; }
    assert_no_rerun
}

@test "run rerun help, from -h, --help and help, gives the usage, the rules in their order, the output and the exit codes, and none calls gh" {
    local invocation
    for invocation in "run rerun -h" "run rerun --help" "help run rerun" "run rerun --repo ${REPO} --help --bogus"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ] || { echo "${invocation}: ${status}" >&2; return 1; }
        [[ "${output}" == "${RUN_RERUN_USAGE}"$'\n'* ]]
        [[ "${output}" == *$'\n'"--run   Always required: the run's id, digits only, above 0."$'\n'* ]]
        [[ "${output}" == *"or, when it has none and a required check of the pull request never ran, the whole run. Which one"$'\n'"is decided from the run and the pull request's checks, never by an option."* ]]
        [[ "${output}" == *$'\n'"--failed, --job, --debug, --all, --json, --jq, --template and --web are not options."$'\n'* ]]
        [[ "${output}" != *"never reruns a whole run"* ]]
        [[ "${output}" != *"no option for a full rerun"* ]]
        [[ "${output}" == *"with \"cfwf: rerun refused: <rule>\" on stderr, which names only the rule:"$'\n'"  default branch                 "*$'\n'"  not an open pull request head  the run's head commit is not the head of an open pull request"* ]]
        [[ "${output}" == *"At most 1000 open pull requests on the branch are looked at; more is a runtime failure."* ]]
        [[ "${output}" == *"(queued, in progress or waiting) exits 4"*"So a run that is refused is never reported as pending."* ]]
        [[ "${output}" == *"So a run that is refused is never reported as pending."*"Otherwise it is refused, after"$'\n'"the rules above:"$'\n'"  no failed jobs and no required check missing"$'\n'* ]]
        [[ "${output}" == *$'\n'"  Rerunning failed jobs of run <id> (attempt <n>)"$'\n'"  Rerunning all jobs of run <id> (attempt <n>): required check <name> never ran"$'\n'"where <n> is the attempt the rerun starts: one more than the run's attempt when it was read."* ]]
        [[ "${output}" == *"the request may still have reached GitHub."* ]]
        [[ "${output}" == *"leaves the run in progress (exit 4)."$'\n'"A run is rerun whatever its attempt."$'\n'* ]]
        [[ "${output}" != *"attempt limit"* && "${output}" != *"or later"* ]]
        [[ "${output}" == *"Exit codes: 0 the rerun was requested; 8 refused by a rule (naming the rule; nothing was"$'\n'"written); 4 the run is still in progress; 9 the run was not found in the repository; 1 a runtime"*"2 a"$'\n'"usage error." ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "run with no subcommand names its one, and a subcommand it does not have is named by its position, each exit 2 with no gh call" {
    run --separate-stderr "${SCRIPT}" run
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: run needs a subcommand (list, view, log, rerun)"$'\n\n'"${RUN_LIST_USAGE}"$'\n'* ]]

    run --separate-stderr "${SCRIPT}" run cancel --repo "${REPO}" --run 123
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: unknown run subcommand (argument 2; its value is not shown)"$'\n\n'"${RUN_LIST_USAGE}"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "run rerun usage errors exit 2 with its usage and nothing on stdout, never echoing a value, before any gh call" {
    prepare_run_rerun
    local repo="--repo ${REPO}" args
    local -a cases=(
        ""
        "${repo}"
        "--run 123"
        "${repo} --run"
        "--repo"
        "${repo} --run 0"
        "${repo} --run 000"
        "${repo} --run abc"
        "${repo} --run -1"
        "${repo} --run 12a"
        "${repo} --run 12345678901234567890"
        "${repo} --run 123 --run 124"
        "${repo} ${repo} --run 123"
        "${repo} --run 123 --failed"
        "${repo} --run 123 --job 1"
        "${repo} --run 123 --debug"
        "${repo} --run 123 --all"
        "${repo} --run 123 --json x"
        "${repo} --run 123 --jq x"
        "${repo} --run 123 --template x"
        "${repo} --run 123 --web"
        "${repo} 123"
        "--repo x/.. --run 123"
        "--repo checkout --run 123"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" run rerun ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${RUN_RERUN_USAGE}"$'\n'* ]]
    done

    run_run_rerun
    [[ "${stderr}" == "cfwf: missing required option --run"$'\n'* ]]
    run --separate-stderr "${SCRIPT}" run rerun --run 123
    [[ "${stderr}" == "cfwf: missing required option --repo"$'\n'* ]]
    run_run_rerun --run
    [[ "${stderr}" == "cfwf: --run needs a value"$'\n'* ]]
    run_run_rerun --run 0
    [[ "${stderr}" == "cfwf: invalid value for --run: it must be a number above 0"$'\n'* ]]
    run_run_rerun --run 000
    [[ "${stderr}" == "cfwf: invalid value for --run: it must be a number above 0"$'\n'* ]]
    run_run_rerun --run 12345678901234567890
    [[ "${stderr}" == "cfwf: invalid value for --run: it must be a number of at most 19 digits"$'\n'* ]]
    run_run_rerun --run -1
    [[ "${stderr}" == "cfwf: invalid value for --run: it must be a number of at most 19 digits"$'\n'* ]]
    run_run_rerun --run 123 --run 124
    [[ "${stderr}" == "cfwf: --run can only be given once"$'\n'* ]]
    run_run_rerun --repo "${REPO}" --run 123
    [[ "${stderr}" == "cfwf: --repo can only be given once"$'\n'* ]]
    run_run_rerun --run 123 --failed
    [[ "${stderr}" == "cfwf: unknown option (argument 7; its value is not shown)"$'\n'* ]]

    # A token-shaped value, as a stray argument or as the run, is never echoed.
    local secret="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    run_run_rerun --run 123 "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 7; its value is not shown)"$'\n'* && "${stderr}" != *"${secret}"* ]]
    run_run_rerun --run "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --run: it must be a number of at most 19 digits"$'\n'* && "${stderr}" != *"${secret}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "run rerun reruns only the failed jobs, once, of a run that is an open pull request's head, after reading the run, the repository and the branch's open pull requests, and prints the attempt it starts" {
    prepare_run_rerun
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning failed jobs of run 123 (attempt 2)" ]
    [ -z "${stderr}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 4 ]
    [[ "$(sed -n 1p "${GH_LOG}")" == "api repos/${REPO}/actions/runs/123 --jq "* ]]
    [ "$(sed -n 2p "${GH_LOG}")" = "api repos/${REPO} --jq .default_branch" ]
    [[ "$(sed -n 3p "${GH_LOG}")" == "pr list --repo ${REPO} --state open --limit 1001 --head feat/x --json number,headRefName,headRefOid,isCrossRepository --jq "* ]]
    [ "$(sed -n 4p "${GH_LOG}")" = "${RUN_RERUN_CALL}" ]
}

@test "run rerun prints the attempt one more than the run's, and reads and reruns a run given with leading zeros as that number, without them" {
    prepare_run_rerun 2
    run_run_rerun --run 00123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning failed jobs of run 123 (attempt 3)" ]
    [ "$(gh_call_count "api repos/${REPO}/actions/runs/123 ")" -eq 1 ]
    [ "$(grep -cxF -- "${RUN_RERUN_CALL}" "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "00123")" -eq 0 ]
}

@test "run rerun accepts a fork's open pull request whose head is the run's, beside one on the branch whose head has moved" {
    prepare_run_rerun
    write_pr_list "$(pull_request 5 feat/x main stranger false true "from a fork" "${MOVED_SHA}")" \
        "$(pull_request 9 feat/x main stranger false true "from another fork" "${RUN_SHA}")"
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning failed jobs of run 123 (attempt 2)" ]
    [ "$(grep -cxF -- "${RUN_RERUN_CALL}" "${GH_LOG}")" -eq 1 ]
}

@test "run rerun reruns a failed run on its third attempt or later, printing the attempt it starts (#1991)" {
    local attempt
    for attempt in 3 5 10; do
        prepare_run_rerun "${attempt}"
        rm -f "${GH_LOG}"
        run_run_rerun --run 123
        if [ "${status}" -ne 0 ]; then
            echo "attempt ${attempt}: ${status} ${stderr}" >&2
            return 1
        fi
        [ "${output}" = "Rerunning failed jobs of run 123 (attempt $((attempt + 1)))" ]
        [ -z "${stderr}" ]
        [ "$(wc -l < "${GH_LOG}")" -eq 4 ]
        [ "$(tail -n 1 "${GH_LOG}")" = "${RUN_RERUN_CALL}" ]
    done

    # A whole-run rerun has no attempt limit either.
    prepare_whole_run_rerun 4
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning all jobs of run 123 (attempt 5): required check pre-release never ran" ]
    [ "$(grep -cxF -- "${RUN_RERUN_ALL_CALL}" "${GH_LOG}")" -eq 1 ]
}

@test "run rerun refuses a run whose head branch is the default branch (exit 8), naming only the rule, before listing pull requests" {
    write_run 123 completed failure "${RUN_SHA}" trunk 1
    write_run_repository trunk
    write_pr_list "$(pull_request 7 trunk main someone false false "a change" "${RUN_SHA}")"
    run_run_rerun --run 123
    assert_rerun_refused "default branch" "${status}" "${output}" "${stderr}"
    [ "$(gh_call_count "pr list ")" -eq 0 ]

    # A branch whose name only starts with the default branch's is another branch.
    write_run 123 completed failure "${RUN_SHA}" trunk-fix 1
    write_pr_list "$(pull_request 7 trunk-fix main someone false false "a change" "${RUN_SHA}")"
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning failed jobs of run 123 (attempt 2)" ]
}

@test "run rerun refuses a run that is not the head of an open pull request on its branch (exit 8): none open there, a head that has moved, or no head branch" {
    prepare_run_rerun
    write_pr_list "$(pull_request 8 feat/y main someone false false "another change" "${RUN_SHA}")"
    run_run_rerun --run 123
    assert_rerun_refused "not an open pull request head" "${status}" "${output}" "${stderr}"

    write_pr_list "$(pull_request 7 feat/x main someone false false "the change" "${MOVED_SHA}")"
    run_run_rerun --run 123
    assert_rerun_refused "not an open pull request head" "${status}" "${output}" "${stderr}"

    write_pr_list
    run_run_rerun --run 123
    assert_rerun_refused "not an open pull request head" "${status}" "${output}" "${stderr}"
    [ "$(gh_call_count "pr list --repo ${REPO} --state open --limit 1001 --head feat/x ")" -eq 3 ]

    # A run with no head branch has no pull request to look for.
    write_run 123 completed failure "${RUN_SHA}" "" 1
    rm -f "${GH_LOG}"
    run_run_rerun --run 123
    assert_rerun_refused "not an open pull request head" "${status}" "${output}" "${stderr}"
    [ "$(gh_call_count "pr list ")" -eq 0 ]
}

@test "run rerun refuses a run that has not completed but breaks a rule (exit 8), never reporting it as pending" {
    prepare_run_rerun 1 in_progress
    write_run 123 queued "" "${RUN_SHA}" main 1
    run_run_rerun --run 123
    assert_rerun_refused "default branch" "${status}" "${output}" "${stderr}"

    write_run 123 waiting "" "${MOVED_SHA}" feat/x 1
    run_run_rerun --run 123
    assert_rerun_refused "not an open pull request head" "${status}" "${output}" "${stderr}"
}

@test "run rerun exits 4 for a run that passes every rule but has not completed, naming its status, writing nothing" {
    local state
    for state in queued in_progress waiting pending requested; do
        prepare_run_rerun 1 "${state}"
        run_run_rerun --run 123
        [ "${status}" -eq 4 ] || { echo "${state}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the run 123 of ${REPO} is ${state}; its failed jobs can be rerun once it is complete" ]
        assert_no_rerun
    done
}

@test "run rerun exits 9 for a run that is not in the repository, and 1 with the repository message when the repository is not there" {
    write_run_repository
    run_run_rerun --run 123
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the run 123 was not found in ${REPO}" ]
    assert_no_rerun

    rm "$(api_fixture "repos/${REPO}").json"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]

    # A run whose repository is then not found when its default branch is read.
    prepare_run_rerun
    rm "$(api_fixture "repos/${REPO}").json"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
    [ "$(gh_call_count "pr list ")" -eq 0 ]
    assert_no_rerun
}

@test "run rerun exits 1 quoting only the first line of gh's error when a read fails, and writes nothing" {
    prepare_run_rerun
    fail_api "repos/${REPO}/actions/runs/123" "gh: Bad Gateway (HTTP 502)"$'\n'"a second line"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the run 123 of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    rm "$(api_fixture "repos/${REPO}/actions/runs/123").fail"

    fail_api "repos/${REPO}"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    rm "$(api_fixture "repos/${REPO}").fail"

    printf '%s\n' "gh: Bad Gateway (HTTP 502)" "a second line" > "${GH_FIXTURES}/pr-list.fail"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the open pull requests of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    assert_no_rerun
}

@test "run rerun exits 1 and writes nothing for a run answer that is not what it expects" {
    write_run_repository
    write_pr_list "$(pull_request 7 feat/x main someone false false "the change" "${RUN_SHA}")"

    write_run 123 completed failure "${RUN_SHA}" feat/x 1 124
    run_run_rerun --run 123
    assert_unexpected_run "another id" "${status}" "${output}" "${stderr}"

    write_run 123 completed failure "${RUN_SHA:1}" feat/x 1
    run_run_rerun --run 123
    assert_unexpected_run "a short head commit" "${status}" "${output}" "${stderr}"

    write_run 123 completed failure "${RUN_SHA:1}g" feat/x 1
    run_run_rerun --run 123
    assert_unexpected_run "a head commit that is not hexadecimal" "${status}" "${output}" "${stderr}"

    write_run 123 "In Progress" "" "${RUN_SHA}" feat/x 1
    run_run_rerun --run 123
    assert_unexpected_run "a status that is not one of GitHub's" "${status}" "${output}" "${stderr}"

    write_run 123 "" "" "${RUN_SHA}" feat/x 1
    run_run_rerun --run 123
    assert_unexpected_run "no status" "${status}" "${output}" "${stderr}"

    local attempt
    for attempt in 0 -1 1.5 null 1234567890 '"01"'; do
        write_run 123 completed failure "${RUN_SHA}" feat/x "${attempt}"
        run_run_rerun --run 123
        assert_unexpected_run "attempt ${attempt}" "${status}" "${output}" "${stderr}"
    done

    # A head branch git would not allow, or one holding a C1 control (which git allows), is never
    # handed to gh pr list or compared with the default branch.
    local branch
    for branch in "a..b" "feat x" $'feat\tx' $'feat/\xc2\x9bx' "-x" "HEAD"; do
        write_run 123 completed failure "${RUN_SHA}" "${branch}" 1
        rm -f "${GH_LOG}"
        run_run_rerun --run 123
        assert_unexpected_run "branch ${branch}" "${status}" "${output}" "${stderr}"
        [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    done
}

@test "run rerun exits 1 and writes nothing for a run row cut short before its end, or with a field after it" {
    # The stand-in that can print an answer as it is, so a row need not come from the jq program.
    prepare_pr_comments
    local answer
    for answer in "123"$'\x1f'"completed"$'\x1f'"failure"$'\x1f'"${RUN_SHA}"$'\x1f'"feat/x"$'\x1f'"1" \
        "123"$'\x1f'"completed"$'\x1f'"failure"$'\x1f'"${RUN_SHA}"$'\x1f'"feat/x"$'\x1f'"1"$'\x1f'"end"$'\x1f'"more"; do
        printf '%s\n' "${answer}" > "$(api_fixture "repos/${REPO}/actions/runs/123").raw"
        rm -f "${GH_LOG}"
        run_run_rerun --run 123
        assert_unexpected_run "row ${answer}" "${status}" "${output}" "${stderr}"
        [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    done
}

@test "run rerun exits 1 and writes nothing for a default branch git would not allow" {
    prepare_run_rerun
    write_run_repository "a..b"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected default branch for ${REPO}" ]
    [ "$(gh_call_count "pr list ")" -eq 0 ]
    assert_no_rerun
}

@test "run rerun exits 1 and writes nothing when the open pull requests read is not what it expects" {
    prepare_run_rerun

    # A pull request gh matched on anything but the exact branch name.
    touch "${GH_FIXTURES}/pr-list.ignore-head"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${RUN_PRS_UNEXPECTED}" ]
    rm "${GH_FIXTURES}/pr-list.ignore-head"

    # A pull request with no head commit, or whose number is not a number.
    write_pr_list "$(pull_request 7 feat/x main someone false false "the change")"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "${RUN_PRS_UNEXPECTED}" ]
    write_pr_list "$(pull_request '"x7"' feat/x main someone false false "the change" "${RUN_SHA}")"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "${RUN_PRS_UNEXPECTED}" ]

    # A count that is not the number of rows that follow.
    printf '2\n7\tfeat/x\t%s\n' "${RUN_SHA}" > "${GH_FIXTURES}/pr-list.out"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${RUN_PRS_UNEXPECTED}" ]
    assert_no_rerun
}

@test "run rerun judges up to 1000 open pull requests on the branch, and with more judges none and exits 1" {
    prepare_run_rerun
    write_branch_pr_list 1000 1000
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning failed jobs of run 123 (attempt 2)" ]

    rm -f "${GH_LOG}"
    write_branch_pr_list 1001 1
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO} has more than 1000 open pull requests on the head branch of the run 123" ]
    assert_no_rerun
}

@test "run rerun exits 1 with nothing on stdout when the rerun request fails, having asked once, a run that already succeeded included" {
    prepare_run_rerun
    printf '%s\n' "gh: Bad Gateway (HTTP 502)" "a second line" > "${GH_FIXTURES}/run-rerun.fail"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not rerun the failed jobs of the run 123 of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    [ "$(grep -cxF -- "${RUN_RERUN_CALL}" "${GH_LOG}")" -eq 1 ]

    # A run that succeeded with a failed job (one that may fail) has its failed jobs rerun, and
    # GitHub's refusal is a runtime failure.
    rm -f "${GH_LOG}"
    write_run 123 completed success "${RUN_SHA}" feat/x 1
    write_run_jobs 123 "30|build|completed|success" "31|flaky|completed|failure"
    printf '%s\n' "HTTP 403: This workflow run cannot be retried" > "${GH_FIXTURES}/run-rerun.fail"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not rerun the failed jobs of the run 123 of ${REPO}: HTTP 403: This workflow run cannot be retried" ]
    [ "$(grep -cxF -- "${RUN_RERUN_CALL}" "${GH_LOG}")" -eq 1 ]
}

RUN_RERUN_ALL_CALL="run rerun 123 --repo ${REPO}"

# The run 123 of prepare_run_rerun, which succeeded on the attempt $1 (1) with no failed job, whose
# open pull request 7 has RUN_SHA as its head and main as its base. main requires build and
# pre-release, and only build has run on RUN_SHA: the pre-release job was never created.
prepare_whole_run_rerun() {
    prepare_run_rerun "${1:-1}"
    write_run 123 completed success "${RUN_SHA}" feat/x "${1:-1}"
    write_run_jobs 123 "30|build|completed|success" "31|optional|completed|skipped" "32|notes|completed|neutral"
    jq -n --arg sha "${RUN_SHA}" '{number: 7, head: {sha: $sha}, base: {ref: "main"}}' | write_api "repos/${REPO}/pulls/7"
    write_protection main build pre-release
    write_no_rulesets main
    write_check_runs "${RUN_SHA}" "$(check_run build success 11 "" "${RUN_SHA}")"
    write_statuses "${RUN_SHA}"
}

@test "run rerun reruns the whole run once, with no --failed, when the run has no failed job and a required check never ran on the pull request's head (#1884)" {
    prepare_whole_run_rerun
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning all jobs of run 123 (attempt 2): required check pre-release never ran" ]
    [ -z "${stderr}" ]
    [ "$(tail -n 1 "${GH_LOG}")" = "${RUN_RERUN_ALL_CALL}" ]
    [ "$(grep -cxF -- "${RUN_RERUN_ALL_CALL}" "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "run rerun ")" -eq 1 ]
    [ "$(gh_call_count "--failed")" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/actions/runs/123/jobs?per_page=100&filter=latest --paginate --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/7 --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/commits/${RUN_SHA}/check-runs?")" -eq 1 ]

    # A check required by a ruleset, from one app, counts too, and the first by name is named.
    write_rulesets main "a-check#15368" build
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning all jobs of run 123 (attempt 2): required check a-check never ran" ]

    # A run on its second attempt starts the third.
    prepare_whole_run_rerun 2
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning all jobs of run 123 (attempt 3): required check pre-release never ran" ]
}

@test "run rerun refuses a run with no failed job whose required checks all have a result (exit 8), writing nothing (#1884)" {
    prepare_whole_run_rerun
    write_check_runs "${RUN_SHA}" "$(check_run build success 11 "" "${RUN_SHA}")" "$(check_run pre-release success 12 "" "${RUN_SHA}")"
    run_run_rerun --run 123
    assert_rerun_refused "no failed jobs and no required check missing" "${status}" "${output}" "${stderr}"

    # One still running, from another run, or a commit status of the name, is not missing either.
    write_check_runs "${RUN_SHA}" "$(check_run build success 11 "" "${RUN_SHA}")" "$(check_run pre-release "" 12 "" "${RUN_SHA}")"
    run_run_rerun --run 123
    assert_rerun_refused "no failed jobs and no required check missing" "${status}" "${output}" "${stderr}"
    write_check_runs "${RUN_SHA}" "$(check_run build success 11 "" "${RUN_SHA}")"
    write_statuses "${RUN_SHA}" "$(commit_status pre-release pending 21)"
    run_run_rerun --run 123
    assert_rerun_refused "no failed jobs and no required check missing" "${status}" "${output}" "${stderr}"

    # A base branch that requires no check has none missing.
    write_branch main
    run_run_rerun --run 123
    assert_rerun_refused "no failed jobs and no required check missing" "${status}" "${output}" "${stderr}"
}

@test "run rerun keeps the failed-jobs path for a failed run without reading its jobs or checks, and for a run that succeeded with a failed job (#1884)" {
    local conclusion
    for conclusion in failure cancelled timed_out startup_failure; do
        prepare_whole_run_rerun
        write_run 123 completed "${conclusion}" "${RUN_SHA}" feat/x 1
        rm -f "${GH_LOG}"
        run_run_rerun --run 123
        if [ "${status}" -ne 0 ]; then
            echo "${conclusion}: ${status}" >&2
            return 1
        fi
        [ "${output}" = "Rerunning failed jobs of run 123 (attempt 2)" ]
        [ "$(wc -l < "${GH_LOG}")" -eq 4 ]
        [ "$(tail -n 1 "${GH_LOG}")" = "${RUN_RERUN_CALL}" ]
        [ "$(gh_call_count "/jobs")" -eq 0 ]
        [ "$(gh_call_count "/pulls/7")" -eq 0 ]
    done

    prepare_whole_run_rerun
    write_run_jobs 123 "30|build|completed|success" "31|flaky|completed|failure"
    rm -f "${GH_LOG}"
    run_run_rerun --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "Rerunning failed jobs of run 123 (attempt 2)" ]
    [ "$(tail -n 1 "${GH_LOG}")" = "${RUN_RERUN_CALL}" ]
    [ "$(gh_call_count "/pulls/7")" -eq 0 ]
}

@test "run rerun still refuses a run with no failed job and a missing required check under the default branch and the open pull request head rules first (#1884)" {
    prepare_whole_run_rerun
    write_run_repository feat/x
    run_run_rerun --run 123
    assert_rerun_refused "default branch" "${status}" "${output}" "${stderr}"

    prepare_whole_run_rerun
    write_pr_list "$(pull_request 7 feat/x main someone false false "the change" "${MOVED_SHA}")"
    run_run_rerun --run 123
    assert_rerun_refused "not an open pull request head" "${status}" "${output}" "${stderr}"
    [ "$(gh_call_count "/jobs")" -eq 0 ]

    # A head that moved after the open pull requests were read is refused too.
    prepare_whole_run_rerun
    jq -n --arg sha "${MOVED_SHA}" '{number: 7, head: {sha: $sha}, base: {ref: "main"}}' | write_api "repos/${REPO}/pulls/7"
    run_run_rerun --run 123
    assert_rerun_refused "not an open pull request head" "${status}" "${output}" "${stderr}"
}

@test "run rerun exits 1 and writes nothing when a read for the whole-run rerun fails, and exits 1 when that rerun request fails (#1884)" {
    prepare_whole_run_rerun
    fail_api "repos/${REPO}/actions/runs/123/jobs"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the jobs of the run 123 of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    assert_no_rerun
    rm "$(api_fixture "repos/${REPO}/actions/runs/123/jobs").fail"

    prepare_whole_run_rerun
    RUN_JOBS_TOTAL=5 write_run_jobs 123 "30|build|completed|success"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "${RUN_UNEXPECTED}" ]
    assert_no_rerun

    prepare_whole_run_rerun
    fail_api "repos/${REPO}/commits/${RUN_SHA}/check-runs"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the check runs of ${RUN_SHA}: gh: Bad Gateway (HTTP 502)" ]
    assert_no_rerun
    rm "$(api_fixture "repos/${REPO}/commits/${RUN_SHA}/check-runs").fail"

    prepare_whole_run_rerun
    fail_api "repos/${REPO}/rules/branches/main"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    assert_no_rerun
    rm "$(api_fixture "repos/${REPO}/rules/branches/main").fail"

    prepare_whole_run_rerun
    printf '%s\n' "gh: Bad Gateway (HTTP 502)" "a second line" > "${GH_FIXTURES}/run-rerun.fail"
    run_run_rerun --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not rerun all jobs of the run 123 of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    [ "$(grep -cxF -- "${RUN_RERUN_ALL_CALL}" "${GH_LOG}")" -eq 1 ]
}

@test "task wait exits 0 at once for an output file no process holds, printing finished and the end of the output, and never calls gh (#1710)" {
    local file="${TEST_TMP}/done.output"
    printf 'line %s\n' $(seq 1 50) > "${file}"
    run --separate-stderr "${SCRIPT}" task wait --output "${file}"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [[ "${output}" == "finished"$'\n'"line 11"$'\n'* ]]
    [[ "${output}" == *$'\n'"line 50" ]]
    [ ! -f "${GH_LOG}" ]
}

@test "task wait exits 4 at the timeout while a process still holds the output file, printing the output so far (#1710)" {
    local file="${TEST_TMP}/running.output" holder
    sleep 30 > "${file}" &
    holder=$!
    run --separate-stderr "${SCRIPT}" task wait --output "${file}" --timeout 1
    kill "${holder}" 2> /dev/null || true
    [ "${status}" -eq 4 ]
    [[ "${output}" == "still running after 1 seconds; run cfwf task wait again to keep waiting"* ]]
}

@test "task wait returns 0 once the process holding the output file exits, before the timeout (#1710)" {
    local file="${TEST_TMP}/finishing.output"
    (sleep 2; printf 'done\n') > "${file}" &
    run --separate-stderr "${SCRIPT}" task wait --output "${file}" --timeout 20
    [ "${status}" -eq 0 ]
    [[ "${output}" == "finished"$'\n'"done" ]]
}

@test "task wait exits 9 for an output file that does not exist, printing nothing on stdout (#1710)" {
    run --separate-stderr "${SCRIPT}" task wait --output "${TEST_TMP}/missing.output"
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the output file ${TEST_TMP}/missing.output was not found" ]
}

@test "task wait refuses (exit 2) a missing --output, a bad or out-of-range --timeout and a repeated option (#1710)" {
    local file="${TEST_TMP}/any.output" args
    : > "${file}"
    for args in "" "--timeout 5" "--output ${file} --timeout 0" "--output ${file} --timeout 571" "--output ${file} --timeout abc" "--output ${file} --timeout -1" "--output ${file} --output ${file}" "--output ${file} --bogus"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" task wait ${args}
        [ "${status}" -eq 2 ] || { echo "${args}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
    done
    run --separate-stderr "${SCRIPT}" task wait --output "${file}" --timeout 570
    [ "${status}" -eq 0 ]
}

@test "task wait help, from -h, --help and help, gives the usage and the exit codes (#1710)" {
    local invocation
    for invocation in "task wait -h" "task wait --help" "help task wait" "help task"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ] || { echo "${invocation}: ${status}" >&2; return 1; }
        [[ "${output}" == "Usage: cfwf task wait --output <file> [--timeout <seconds>]"* ]]
        [[ "${output}" == *"4  it is still running at the timeout"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

# --- run list, run view and run log ---------------------------------------------

RUN_LIST_USAGE="Usage: cfwf run list --repo <owner/repo> --branch <name> [--workflow <name>] [--limit <n>]"
RUN_VIEW_USAGE="Usage: cfwf run view --repo <owner/repo> --run <id>"
RUN_LOG_USAGE="Usage: cfwf run log --repo <owner/repo> --run <id> [--job <id>] [--lines <n>]"
RUN_CREATED="2026-10-30T10:00:00Z"

# Writes the run $1 as the REST API gives it: status $2, conclusion $3 ("" for null), head branch $4
# ("" for null), workflow name $5 (build) and event $6 (push).
write_view_run() {
    jq -n --argjson id "$1" --arg status "$2" --arg conclusion "$3" --arg sha "${RUN_SHA}" --arg branch "$4" \
        --arg name "${5-build}" --arg event "${6:-push}" --arg created "${RUN_CREATED}" \
        '{id: $id, name: $name, event: $event, status: $status,
          conclusion: (if $conclusion == "" then null else $conclusion end), head_sha: $sha,
          head_branch: (if $branch == "" then null else $branch end), run_attempt: 1, created_at: $created}' \
        | write_api "repos/${REPO}/actions/runs/$1"
}

# Writes the jobs of the run $1: each further argument is "id|name|status|conclusion" (conclusion
# "" for null); the total GitHub gives is the number of them unless RUN_JOBS_TOTAL is set.
write_run_jobs() {
    local run="$1" job
    shift
    for job in "$@"; do
        IFS='|' read -r id name status conclusion <<< "${job}"
        jq -n --argjson id "${id}" --arg name "${name}" --arg status "${status}" --arg conclusion "${conclusion}" \
            '{id: $id, name: $name, status: $status, conclusion: (if $conclusion == "" then null else $conclusion end), run_id: 1}'
    done | jq -s --argjson total "${RUN_JOBS_TOTAL:--1}" '{total_count: (if $total < 0 then length else $total end), jobs: .}' \
        | write_api "repos/${REPO}/actions/runs/${run}/jobs"
}

# Writes the job $1 of the run $2 with the status $3 (completed).
write_run_job() {
    jq -n --argjson id "$1" --argjson run "$2" --arg status "${3:-completed}" '{id: $id, run_id: $run, status: $status, name: "test"}' \
        | write_api "repos/${REPO}/actions/jobs/$1"
}

# Writes the --log-failed answer for the run $1 (or, as job-$1, for that job) from stdin.
write_run_log() {
    cat > "${GH_FIXTURES}/run-log-$1.txt"
}

run_cfwf_run() {
    run --separate-stderr "${SCRIPT}" run "$@"
}

@test "run list, run view and run log help, from -h, --help and help, give each usage and none calls gh; help run gives all four" {
    local invocation
    for invocation in "run list -h" "run list --help" "help run list"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${RUN_LIST_USAGE}"$'\n'* ]]
        [[ "${output}" == *"there is never an event filter."* ]]
        [[ "${output}" == *"--limit     The most runs listed, from 1 to 50 (default 20)."* ]]
        [[ "${output}" == *"  <run id>  <workflow>  <status>  <conclusion>  <head SHA>  <event>  <created at>"* ]]
        [[ "${output}" == *"Exit codes: 0 listed (none included); 9 the repository has no workflow of that --workflow; 1 a"* ]]
    done
    for invocation in "run view -h" "run view --help" "help run view"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${RUN_VIEW_USAGE}"$'\n'* ]]
        [[ "${output}" == *"  head_sha     the run's head commit: 40 hexadecimal digits"* ]]
        [[ "${output}" == *"  job  <job id>  <name>  <status>  <conclusion>"* ]]
        [[ "${output}" == *"Exit codes: 0 printed; 9 the run was not found in the repository; 1 a runtime failure"* ]]
    done
    for invocation in "run log -h" "run log --help" "help run log"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${RUN_LOG_USAGE}"$'\n'* ]]
        [[ "${output}" == *"--lines        The most of the last lines of each failed step kept, from 1 to 2000 (default 200);"* ]]
        [[ "${output}" == *"--context      With --grep: also print this many lines either side of each match, from 0 to 20"* ]]
        [[ "${output}" == *"--max-matches  With --grep: the most matches printed, across every failed step, from 1 to 1000"* ]]
        [[ "${output}" == *"  cfwf run log --repo <owner/repo> --run <id> --grep 'not ok|##\\[error\\]|FAIL' --context 5"* ]]
        [[ "${output}" == *"  summary jobs=<a> steps=<b> lines=<c> redacted=<d> masked=<e> matches=<f> cut=<g>"* ]]
        [[ "${output}" == *"  | <n>- <text>   a context line of a match"* ]]
        [[ "${output}" == *"  summary jobs=<a> steps=<b> lines=<c> redacted=<d> masked=<e>"* ]]
        [[ "${output}" == *"[cfwf: line redacted: token]"* ]]
        [[ "${output}" == *"A 40-digit"$'\n'"              commit SHA is kept"* ]]
        [[ "${output}" == *"Output over 262144 bytes (256 KiB) is refused (exit 1) and none of it is printed"* ]]
        [[ "${output}" == *"Exit codes: 0 printed; 4 the run or the job has not completed; 9 the run or the job was not found"* ]]
    done
    for invocation in "help run" "run -h" "run --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${RUN_LIST_USAGE}"$'\n'*$'\n\n'"${RUN_VIEW_USAGE}"$'\n'*$'\n\n'"${RUN_LOG_USAGE}"$'\n'*$'\n\n'"${RUN_RERUN_USAGE}"$'\n'* ]]
    done
    run "${SCRIPT}" help
    local listed=$'\n'"  run list                 List a repository's Actions runs for a branch or a commit, newest first"$'\n'
    listed+="  run view                 Print an Actions run's status and jobs (exit 9 when not found)"$'\n'
    listed+="  run log                  Print the tail of a run's failed steps' logs, or search them (exit 4 while it runs, 9 when not found)"$'\n'
    listed+="  run rerun                Rerun"
    [[ "${output}" == *"${listed}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "run list, run view and run log usage errors exit 2 with that subcommand's usage and nothing on stdout, never echoing a value, before any gh call" {
    local repo="--repo ${REPO}" args
    local -a list_cases=(
        "" "--branch main" "${repo}" "${repo} --branch main --sha ${RUN_SHA}" "${repo} --sha ${RUN_SHA:1}"
        "${repo} --sha ${RUN_SHA}g" "${repo} --branch -x" "${repo} --branch a..b" "${repo} --branch main --branch main"
        "${repo} --branch main --workflow -x" "${repo} --branch main --limit 0" "${repo} --branch main --limit 51"
        "${repo} --branch main --limit 99999999999999999999" "${repo} --branch main --limit x"
        "${repo} --branch main --json x" "${repo} --branch main --jq x" "${repo} --branch main --template x"
        "${repo} --branch main --paginate" "${repo} --branch main --event push" "${repo} --branch main --run 1"
        "${repo} --branch main --lines 3"
    )
    for args in "${list_cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" run list ${args}
        [ "${status}" -eq 2 ] || { echo "run list accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${RUN_LIST_USAGE}"$'\n'* ]]
    done
    run_cfwf_run list --repo "${REPO}" --branch $'feat/\xc2\x9bx'
    [ "${status}" -eq 2 ]
    run_cfwf_run list --repo "${REPO}" --branch main --workflow $'build\x01'
    [ "${status}" -eq 2 ]
    run_cfwf_run list --repo "${REPO}" --branch main --workflow "   "
    [ "${status}" -eq 2 ]
    run_cfwf_run list --repo "${REPO}"
    [[ "${stderr}" == "cfwf: one of --branch or --sha is required"$'\n'* ]]
    run_cfwf_run list --repo "${REPO}" --branch main --sha "${RUN_SHA}"
    [[ "${stderr}" == "cfwf: --branch and --sha cannot be given together"$'\n'* ]]
    run_cfwf_run list --repo "${REPO}" --branch main --limit 51
    [[ "${stderr}" == "cfwf: invalid value for --limit: it must be a number from 1 to 50"$'\n'* ]]

    local -a view_cases=("" "${repo}" "--run 123" "${repo} --run 0" "${repo} --run abc" "${repo} --run 12345678901234567890"
        "${repo} --run 1 --run 2" "${repo} --run 1 --json x" "${repo} --run 1 --log" "${repo} --run 1 --job 2" "${repo} --run 1 --attempt 1")
    for args in "${view_cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" run view ${args}
        [ "${status}" -eq 2 ] || { echo "run view accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${RUN_VIEW_USAGE}"$'\n'* ]]
    done

    local -a log_cases=("" "${repo}" "--run 123" "${repo} --run 0" "${repo} --run 1 --job 0" "${repo} --run 1 --job x"
        "${repo} --run 1 --lines 0" "${repo} --run 1 --lines 2001" "${repo} --run 1 --lines 1 --lines 2"
        "${repo} --run 1 --log" "${repo} --run 1 --json x" "${repo} --run 1 --attempt 1" "${repo} --run 1 --branch main"
        "${repo} --run 1 --grep (" "${repo} --run 1 --grep x --grep y"
        "${repo} --run 1 --grep x --lines 3" "${repo} --run 1 --grep x --from-line 2"
        "${repo} --run 1 --context 1" "${repo} --run 1 --max-matches 5" "${repo} --run 1 --grep x --context 21"
        "${repo} --run 1 --grep x --context -1" "${repo} --run 1 --grep x --context x" "${repo} --run 1 --grep x --max-matches 0"
        "${repo} --run 1 --grep x --max-matches 1001" "${repo} --run 1 --from-line 0" "${repo} --run 1 --from-line x"
        "${repo} --run 1 --from-line 1 --from-line 2" "${repo} --run 1 --grep")
    for args in "${log_cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" run log ${args}
        [ "${status}" -eq 2 ] || { echo "run log accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${RUN_LOG_USAGE}"$'\n'* ]]
    done
    run_cfwf_run log --repo "${REPO}" --run 1 --lines 2001
    [[ "${stderr}" == "cfwf: invalid value for --lines: it must be a number from 1 to 2000"$'\n'* ]]
    run_cfwf_run log --repo "${REPO}" --run 1 --grep x --context 21
    [[ "${stderr}" == "cfwf: invalid value for --context: it must be a number from 0 to 20"$'\n'* ]]
    run_cfwf_run log --repo "${REPO}" --run 1 --grep x --max-matches 1001
    [[ "${stderr}" == "cfwf: invalid value for --max-matches: it must be a number from 1 to 1000"$'\n'* ]]
    run_cfwf_run log --repo "${REPO}" --run 1 --grep x --lines 3
    [[ "${stderr}" == "cfwf: --grep cannot be given with --lines or --from-line"$'\n'* ]]
    run_cfwf_run log --repo "${REPO}" --run 1 --context 1
    [[ "${stderr}" == "cfwf: --context and --max-matches need --grep"$'\n'* ]]
    local pattern
    for pattern in "" $'a\x01b' $'a\tb' "$(printf 'a%.0s' $(seq 1 257))" "(" "a[" ; do
        run_cfwf_run log --repo "${REPO}" --run 1 --grep "${pattern}"
        [ "${status}" -eq 2 ] || { echo "run log accepted the pattern: ${pattern} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${RUN_LOG_USAGE}"$'\n'* ]]
    done
    local hidden="(ghp_${RANDOM}zz"
    run_cfwf_run log --repo "${REPO}" --run 1 --grep "${hidden}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"${hidden}"* ]]

    local secret="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    run_cfwf_run list --repo "${REPO}" --branch main "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"${secret}"* ]]
    run_cfwf_run log --repo "${REPO}" --run "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"${secret}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "run list --branch main lists the runs started by any event, newest first, with no event filter, in one read" {
    write_run_list "11|build|completed|success|${RUN_SHA}|main|push|2026-10-30T09:00:00Z" \
        "12|deploy|completed||${RUN_SHA}|main|workflow_dispatch|2026-10-30T09:05:00Z" \
        $'13|lint\x1bx|in_progress||'"${RUN_SHA}|main|push|2026-10-30T09:10:00Z"
    run_cfwf_run list --repo "${REPO}" --branch main
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected="13"$'\t'"lint x"$'\t'"in_progress"$'\t'"-"$'\t'"${RUN_SHA}"$'\t'"push"$'\t'"2026-10-30T09:10:00Z"$'\n'
    expected+="12"$'\t'"deploy"$'\t'"completed"$'\t'"-"$'\t'"${RUN_SHA}"$'\t'"workflow_dispatch"$'\t'"2026-10-30T09:05:00Z"$'\n'
    expected+="11"$'\t'"build"$'\t'"completed"$'\t'"success"$'\t'"${RUN_SHA}"$'\t'"push"$'\t'"2026-10-30T09:00:00Z"
    [ "${output}" = "${expected}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    grep -qF -- "run list --repo ${REPO} --branch=main --all --limit 20 --json databaseId,workflowName,status,conclusion,headSha,headBranch,event,createdAt --jq" "${GH_LOG}"
    [ "$(sed 's/--json [^ ]*//' "${GH_LOG}" | grep -cE -- "--event|event=")" -eq 0 ]
}

@test "run list --sha asks for the commit, passes --workflow and --limit with = and as given, and an empty list prints nothing" {
    write_run_list
    run_cfwf_run list --repo "${REPO}" --sha "${RUN_SHA^^}" --workflow "Build and test" --limit 50
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    grep -qF -- "run list --repo ${REPO} --commit=${RUN_SHA} --workflow=Build and test --all --limit 50 " "${GH_LOG}"
}

@test "run list exits 1 with nothing printed for a row whose head branch or commit is not the one asked for, or an answer that is not what it expects" {
    write_run_list "11|build|completed|success|${RUN_SHA}|feat/x|push|2026-10-30T09:00:00Z"
    run_cfwf_run list --repo "${REPO}" --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the runs of ${REPO}" ]

    write_run_list "11|build|completed|success|${MOVED_SHA}|main|push|2026-10-30T09:00:00Z"
    run_cfwf_run list --repo "${REPO}" --sha "${RUN_SHA}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]

    printf '2\n11\tbuild\tcompleted\tsuccess\t%s\tpush\t2026-10-30T09:00:00Z\tmain\n' "${RUN_SHA}" > "${GH_FIXTURES}/run-list.out"
    run_cfwf_run list --repo "${REPO}" --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]

    printf '1\n11\tbuild\tCompleted\tsuccess\t%s\tpush\t2026-10-30T09:00:00Z\tmain\n' "${RUN_SHA}" > "${GH_FIXTURES}/run-list.out"
    run_cfwf_run list --repo "${REPO}" --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "run list exits 9 for a workflow the repository does not have, 1 when the repository is not there, and 1 quoting gh for any other failure" {
    write_run_repository
    printf 'could not find any workflows named nope\n' > "${GH_FIXTURES}/run-list.fail"
    run_cfwf_run list --repo "${REPO}" --branch main --workflow nope
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the --workflow was not found in ${REPO}" ]

    rm -f "$(api_fixture "repos/${REPO}").json"
    run_cfwf_run list --repo "${REPO}" --branch main --workflow nope
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: "* && "${stderr}" != *"--workflow was not found"* ]]

    printf 'HTTP 502: Bad Gateway\nsecond line\n' > "${GH_FIXTURES}/run-list.fail"
    run_cfwf_run list --repo "${REPO}" --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the runs of ${REPO}: HTTP 502: Bad Gateway" ]
}

@test "run view prints the run's eight keys then its jobs sorted by id, - for none, every value printable, from the run and every page of its jobs" {
    write_view_run 123 completed failure feat/x $'build\x1b[31m and test'
    write_run_jobs 123 "30|test|completed|failure" "4|lint|completed|success" $'200|deploy\x01it|queued|'
    run_cfwf_run view --repo "${REPO}" --run 123
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected="status"$'\t'"completed"$'\n'"conclusion"$'\t'"failure"$'\n'"head_sha"$'\t'"${RUN_SHA}"$'\n'
    expected+="head_branch"$'\t'"feat/x"$'\n'"workflow"$'\t'"build [31m and test"$'\n'"event"$'\t'"push"$'\n'
    expected+="attempt"$'\t'"1"$'\n'"created_at"$'\t'"${RUN_CREATED}"$'\n'
    expected+="job"$'\t'"4"$'\t'"lint"$'\t'"completed"$'\t'"success"$'\n'
    expected+="job"$'\t'"30"$'\t'"test"$'\t'"completed"$'\t'"failure"$'\n'
    expected+="job"$'\t'"200"$'\t'"deploy it"$'\t'"queued"$'\t'"-"
    [ "${output}" = "${expected}" ]
    grep -qF -- "api repos/${REPO}/actions/runs/123/jobs?per_page=100&filter=latest --paginate --jq" "${GH_LOG}"

    write_view_run 124 in_progress "" ""
    write_run_jobs 124
    run_cfwf_run view --repo "${REPO}" --run 124
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"conclusion"$'\t'"-"$'\n'"head_sha"* && "${output}" == *"head_branch"$'\t'"-"$'\n'* && "${output}" != *"job"$'\t'* ]]
}

@test "run view exits 9 for a run that is not there, 1 when the repository is not there, and 1 for jobs that do not add up or a failed read" {
    write_run_repository
    run_cfwf_run view --repo "${REPO}" --run 123
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the run 123 was not found in ${REPO}" ]

    rm -f "$(api_fixture "repos/${REPO}").json"
    run_cfwf_run view --repo "${REPO}" --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]

    write_view_run 123 completed failure feat/x
    RUN_JOBS_TOTAL=3 write_run_jobs 123 "30|test|completed|failure"
    run_cfwf_run view --repo "${REPO}" --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the run 123 of ${REPO}" ]

    fail_api "repos/${REPO}/actions/runs/123/jobs"
    run_cfwf_run view --repo "${REPO}" --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the jobs of the run 123 of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
}

@test "run log prints each failed step's header in the order the log gives them, its lines after |, and the summary last" {
    write_view_run 123 completed failure feat/x
    printf 'build\tRun tests\tone\nbuild\tRun tests\t\nlint\tCheck\tthree\nbuild\tRun tests\ttwo\nbuild\tUNKNOWN STEP\tfour\n' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected=$'== job build step Run tests\n| one\n|\n| two\n== job lint step Check\n| three\n== job build step UNKNOWN STEP\n| four\n'
    expected+="summary jobs=2 steps=3 lines=5 redacted=0 masked=0"
    [ "${output}" = "${expected}" ]
    [ "$(gh_call_count "run view 123 --repo ${REPO} --log-failed")" -eq 1 ]
}

@test "run log keeps only the last --lines lines of each step and cuts a long line at a character boundary" {
    write_view_run 123 completed failure feat/x
    {
        local n
        for n in 1 2 3 4 5; do printf 'build\tstep\tline %s\n' "${n}"; done
        printf 'build\tlong\t%s\n' "$(printf 'x%.0s' $(seq 1 999))é and more"
    } | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --lines 3
    [ "${status}" -eq 0 ]
    [[ "${output}" == $'== job build step step\n| line 3\n| line 4\n| line 5\n== job build step long\n| '* ]]
    local long
    long="$(sed -n 6p <<< "${output}")"
    [ "${long}" = "| $(printf 'x%.0s' $(seq 1 999)) [cut]" ]
    [[ "${output}" == *$'\n'"summary jobs=1 steps=2 lines=4 redacted=0 masked=0" ]]
}

@test "run log replaces a line holding a token whole, masks long hex and base64 runs, and keeps a commit SHA, *** and host paths" {
    write_view_run 123 completed failure feat/x
    local token="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    {
        printf 'build\tstep\tusing %s here\n' "${token}"
        printf 'build\tstep\tcommit %s kept\n' "${RUN_SHA}"
        printf 'build\tstep\thex %s1 masked\n' "${RUN_SHA}"
        printf 'build\tstep\tdigest sha256:%s\n' "$(printf 'ab%.0s' $(seq 1 32))"
        printf 'build\tstep\tb64 QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAx== end\n'
        printf 'build\tstep\tpath /home/runner/work/credfeto-orchestrator/credfeto-orchestrator and ***\n'
    } | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"${token}"* ]]
    local expected=$'== job build step step\n| [cfwf: line redacted: token]\n'
    expected+="| commit ${RUN_SHA} kept"$'\n'"| hex *** masked"$'\n'"| digest sha256:***"$'\n'"| b64 *** end"$'\n'
    expected+="| path /home/runner/work/credfeto-orchestrator/credfeto-orchestrator and ***"$'\n'
    expected+="summary jobs=1 steps=1 lines=6 redacted=1 masked=3"
    [ "${output}" = "${expected}" ]
}

@test "run log removes ANSI sequences, turns controls into spaces, prints bytes of invalid UTF-8 as ? and never lets a line pass for a header" {
    write_view_run 123 completed failure feat/x
    printf 'build\tstep\t\033[31mred\033[0m a\rb c\302\233d\342\200\250e\nbuild\tstep\tbad \377 é\nbuild\tstep\t== job fake step x\nbuild\tstep\tsummary jobs=9\n' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 0 ]
    local expected=$'== job build step step\n| red a b c d e\n| bad ? ??\n| == job fake step x\n| summary jobs=9\n'
    expected+="summary jobs=1 steps=1 lines=4 redacted=0 masked=0"
    [ "${output}" = "${expected}" ]
}

@test "run log exits 4 for a run that has not completed before reading any log, and when gh says it is still in progress" {
    write_view_run 123 in_progress "" feat/x
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 4 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the run 123 of ${REPO} is in_progress; its logs can be read once it is complete" ]
    [ "$(gh_call_count "run view ")" -eq 0 ]

    write_view_run 123 completed failure feat/x
    printf 'run 123 is still in progress; logs will be available when it is complete\n' > "${GH_FIXTURES}/run-log-123.fail"
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 4 ]
    [ -z "${output}" ]
}

@test "run log --job reads only that job's failed steps, and exits 9 for a job that is not there or not of the run, and 4 while it runs" {
    write_view_run 123 completed failure feat/x
    write_run_repository
    write_run_job 456 123
    printf 'test\tstep\tonly this job\n' | write_run_log job-456
    run_cfwf_run log --repo "${REPO}" --run 123 --job 456
    [ "${status}" -eq 0 ]
    [ "${output}" = $'== job test step step\n| only this job\nsummary jobs=1 steps=1 lines=1 redacted=0 masked=0' ]
    [ "$(gh_call_count "run view --job 456 --repo ${REPO} --log-failed")" -eq 1 ]

    write_run_job 457 999
    run_cfwf_run log --repo "${REPO}" --run 123 --job 457
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the job 457 is not a job of the run 123 of ${REPO}" ]

    run_cfwf_run log --repo "${REPO}" --run 123 --job 458
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the job 458 was not found in ${REPO}" ]

    write_run_job 459 123 in_progress
    run_cfwf_run log --repo "${REPO}" --run 123 --job 459
    [ "${status}" -eq 4 ]
    [ "$(gh_call_count "run view --job 459")" -eq 0 ]
}

@test "run log exits 9 for a run that is not there, 1 when the repository is not, 1 with nothing printed when gh fails or the log is not what it expects, and prints only the zero summary for no failed step" {
    write_run_repository
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the run 123 was not found in ${REPO}" ]

    write_view_run 123 completed failure feat/x
    printf 'HTTP 410: logs have expired\n' > "${GH_FIXTURES}/run-log-123.fail"
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the logs of the run 123 of ${REPO}: HTTP 410: logs have expired" ]

    rm -f "${GH_FIXTURES}/run-log-123.fail"
    printf 'build\tstep\tfine\nno tabs here\n' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected log for the run 123 of ${REPO}" ]

    : | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 0 ]
    [ "${output}" = "summary jobs=0 steps=0 lines=0 redacted=0 masked=0" ]

    rm -f "$(api_fixture "repos/${REPO}").json" "$(api_fixture "repos/${REPO}/actions/runs/123").json"
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 1 ]
}

@test "run log refuses output over 256 KiB whole, printing none of it" {
    write_view_run 123 completed failure feat/x
    local step
    for step in 1 2 3 4 5 6; do
        printf 'build\tstep %s\t%s\n' "${step}" "$(printf 'y%.0s' $(seq 1 900))"
    done > "${TEST_TMP}/one.txt"
    local n
    for n in $(seq 1 60); do cat "${TEST_TMP}/one.txt"; done | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --lines 2000
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: the failed steps' logs of the run 123 of ${REPO} are "*" bytes, more than the 262144 cfwf prints, so none is printed; use a smaller --lines, or --job for one job" ]]

    run_cfwf_run log --repo "${REPO}" --run 123 --lines 40
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"summary jobs=1 steps=6 lines=240 redacted=0 masked=0" ]]

    run_cfwf_run log --repo "${REPO}" --run 123 --grep y --max-matches 1000
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: the failed steps' logs of the run 123 of ${REPO} are "*" bytes, more than the 262144 cfwf prints, so none is printed; use a smaller --context or --max-matches, or --job for one job" ]]

    run_cfwf_run log --repo "${REPO}" --run 123 --grep y --max-matches 100
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"summary jobs=1 steps=6 lines=100 redacted=0 masked=0 matches=360 cut=260" ]]
}

@test "run log --grep finds a match far outside the tail and prints it with its line number within its step (#1880)" {
    write_view_run 123 completed failure feat/x
    awk 'BEGIN { for (n = 1; n <= 4000; n++) printf "build\ttest\t%s\n", (n == 1978 ? "not ok 7 the thing" : "ok " n) }' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"not ok"* ]]

    run_cfwf_run log --repo "${REPO}" --run 123 --grep 'not ok'
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = $'== job build step test\n| 1978: not ok 7 the thing\nsummary jobs=1 steps=1 lines=1 redacted=0 masked=0 matches=1 cut=0' ]
    [ "$(gh_call_count "run view 123 --repo ${REPO} --log-failed")" -eq 2 ]
}

@test "run log --grep --context prints numbered context lines, merges overlapping groups and marks a gap with | --, per step (#1880)" {
    write_view_run 123 completed failure feat/x
    {
        printf 'build\ta\tx1\nlint\tb\ty1\nbuild\ta\tx2\nbuild\ta\tFAIL one\nlint\tb\tFAIL b\nbuild\ta\tx4\n'
        printf 'build\ta\tFAIL two\nbuild\ta\tx6\nlint\tb\ty3\nlint\tc\tnothing here\n'
        printf 'build\ta\tx7\nbuild\ta\tx8\nbuild\ta\tx9\nbuild\ta\tFAIL three\nbuild\ta\tx11\n'
    } | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --grep FAIL --context 1
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected=$'== job build step a\n| 2- x2\n| 3: FAIL one\n| 4- x4\n| 5: FAIL two\n| 6- x6\n| --\n| 9- x9\n| 10: FAIL three\n| 11- x11\n'
    expected+=$'== job lint step b\n| 1- y1\n| 2: FAIL b\n| 3- y3\n'
    expected+="summary jobs=2 steps=2 lines=11 redacted=0 masked=0 matches=4 cut=0"
    [ "${output}" = "${expected}" ]
}

@test "run log --max-matches caps the matches printed across the log, counting the rest as cut, and a later match can still show as context (#1880)" {
    write_view_run 123 completed failure feat/x
    printf 'build\ttest\t%s\n' l1 l2 l3 'FAIL a' l5 'FAIL b' l7 'FAIL c' l9 l10 l11 'FAIL d' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --grep FAIL --context 2 --max-matches 2
    [ "${status}" -eq 0 ]
    local expected=$'== job build step test\n| 2- l2\n| 3- l3\n| 4: FAIL a\n| 5- l5\n| 6: FAIL b\n| 7- l7\n| 8- FAIL c\n'
    expected+="summary jobs=1 steps=1 lines=7 redacted=0 masked=0 matches=4 cut=2"
    [ "${output}" = "${expected}" ]
}

@test "run log --grep that matches nothing prints only the summary and exits 0, and takes a 256-byte pattern (#1880)" {
    write_view_run 123 completed failure feat/x
    printf 'build\ttest\tall fine\n' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --grep "$(printf 'a%.0s' $(seq 1 256))"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "summary jobs=0 steps=0 lines=0 redacted=0 masked=0 matches=0 cut=0" ]
}

@test "run log --grep takes backslashes as the pattern gives them, so an escaped bracket matches a literal ##[error] line (#1880)" {
    write_view_run 123 completed failure feat/x
    printf 'build\ttest\t%s\n' 'ok 1' '##[error]Process completed with exit code 1.' '#error' '##e' 'not ok 2 thing' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --grep 'not ok|##\[error\]|FAIL'
    [ "${status}" -eq 0 ]
    local expected=$'== job build step test\n| 2: ##[error]Process completed with exit code 1.\n| 5: not ok 2 thing\n'
    expected+="summary jobs=1 steps=1 lines=2 redacted=0 masked=0 matches=2 cut=0"
    [ "${output}" = "${expected}" ]
}

@test "run log --grep takes POSIX intervals and bracket classes as grep -E does, and --context 0 as no context (#1880)" {
    write_view_run 123 completed failure feat/x
    printf 'build\ttest\t%s\n' 'aa' 'a{2}' 'a b' 'ab' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --grep '^a{2}$'
    [ "${status}" -eq 0 ]
    [ "${output}" = $'== job build step test\n| 1: aa\nsummary jobs=1 steps=1 lines=1 redacted=0 masked=0 matches=1 cut=0' ]
    run_cfwf_run log --repo "${REPO}" --run 123 --grep 'a[[:space:]]b' --context 0
    [ "${status}" -eq 0 ]
    [ "${output}" = $'== job build step test\n| 3: a b\nsummary jobs=1 steps=1 lines=1 redacted=0 masked=0 matches=1 cut=0' ]
}

@test "run log --grep still redacts a token line, masks long runs and makes text printable, keeping each line's number (#1880)" {
    write_view_run 123 completed failure feat/x
    local token="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    {
        printf 'build\tstep\tusing %s token\n' "${token}"
        printf 'build\tstep\thex %s1 token\n' "${RUN_SHA}"
        printf 'build\tstep\t\033[31mred\033[0m\ttoken\n'
        printf 'build\tstep\tskipped\n'
    } | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --grep '^red token$|token$'
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"${token}"* ]]
    local expected=$'== job build step step\n| 1: [cfwf: line redacted: token]\n| 2: hex *** token\n| 3: red token\n'
    expected+="summary jobs=1 steps=1 lines=3 redacted=1 masked=1 matches=3 cut=0"
    [ "${output}" = "${expected}" ]
}

@test "run log --from-line prints a numbered window of each failed step, --lines long, and no header for a step too short for it (#1880)" {
    write_view_run 123 completed failure feat/x
    printf 'build\ta\ta1\nbuild\tb\tb1\nbuild\ta\ta2\nbuild\ta\ta3\nbuild\tb\tb2\nbuild\ta\ta4\nbuild\ta\t\nbuild\ta\ta6\n' | write_run_log 123
    run_cfwf_run log --repo "${REPO}" --run 123 --from-line 3 --lines 2
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = $'== job build step a\n| 3: a3\n| 4: a4\nsummary jobs=1 steps=1 lines=2 redacted=0 masked=0' ]

    run_cfwf_run log --repo "${REPO}" --run 123 --from-line 2
    [ "${status}" -eq 0 ]
    [ "${output}" = $'== job build step a\n| 2: a2\n| 3: a3\n| 4: a4\n| 5:\n| 6: a6\n== job build step b\n| 2: b2\nsummary jobs=1 steps=2 lines=6 redacted=0 masked=0' ]
}

@test "run list, run view and run log fail (exit 1) when gh is not installed, after the options are checked" {
    mkdir -p "${TEST_TMP}/git-only"
    ln -s "$(command -v git)" "${TEST_TMP}/git-only/git"
    local bash_path command
    bash_path="$(command -v bash)"
    for command in "run list --branch main" "run view --run 1" "run log --run 1"; do
        # shellcheck disable=SC2086  # each command is split into its words on purpose
        run --separate-stderr env PATH="${TEST_TMP}/git-only" "${bash_path}" "${SCRIPT}" ${command} --repo "${REPO}"
        [ "${status}" -eq 1 ] || { echo "${command}: ${status}" >&2; return 1; }
        [[ "${stderr}" == "cfwf: gh is not installed"* ]]
    done
}
