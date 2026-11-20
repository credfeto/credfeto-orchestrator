#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- help and usage ------------------------------------------------------------

@test "help, --help and -h print the usage listing every command and exit 0" {
    local flag
    for flag in help --help -h; do
        run "${SCRIPT}" "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf <command>"* ]]
        [[ "${output}" == *"workflow-status --set"* ]]
        [[ "${output}" == *"workflow-status --check"* ]]
        [[ "${output}" == *"closing-issue-labels"* ]]
        [[ "${output}" == *"issue create"* ]]
        [[ "${output}" == *"issue view"*"(exit 9 when not found)"* ]]
        [[ "${output}" == *"issue plan-status"* ]]
        [[ "${output}" == *$'\n'"  issue list               List a repository's open issues, highest priority first, one line each"$'\n'* ]]
        [[ "${output}" == *$'\n'"  issue search             Search one repository's issues by words in their title or body, one line each"$'\n'* ]]
        [[ "${output}" == *$'\n'"  repo view                Print a repository's default branch, visibility, merge methods and description"$'\n'* ]]
        [[ "${output}" == *$'\n'"  repo collaborators       List a repository's collaborators and their roles, sorted by login in the C locale"$'\n'* ]]
        [[ "${output}" == *$'\n'"  auth status              Print the authenticated login, the host and the gh version, never a token"$'\n'* ]]
        [[ "${output}" == *$'\n'"  branch required-checks   Print the checks a branch requires, from its protection and rulesets (exit 9 when not found)"$'\n'* ]]
        [[ "${output}" == *"body check"*"exit 8 when refused"* ]]
        [[ "${output}" == *"pr checks"*"(exit 0, 3, 4 or 5)"* ]]
        [[ "${output}" == *"pr view"*"(exit 9 when not found)"* ]]
        [[ "${output}" == *"pr diff"*"(exit 9 when not found)"* ]]
        [[ "${output}" == *"comment add"* ]]
        [[ "${output}" == *$'\n'"  comment edit             Replace the body of the agent's own comment, by id, and print its URL (exit 8 refused, 9 not found)"$'\n'* ]]
        [[ "${output}" == *"release view"*"(exit 9 when it has none)"* ]]
        [[ "${output}" == *"release list"* ]]
        [[ "${output}" == *"tag view"*"(exit 9 when not found)"* ]]
        [[ "${output}" == *"run rerun"*"(exit 4 while it runs, 8 when refused, 9 when not found)"* ]]
    done
}

@test "help <command> prints the usage of that command" {
    run "${SCRIPT}" help workflow-status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--repo <owner/repo> (--pr <n> | --issue <n>) --status <name>"* ]]

    run "${SCRIPT}" help closing-issue-labels
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf closing-issue-labels --repo <owner/repo> --pr <n>"* ]]

    run "${SCRIPT}" help issue
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf issue create --repo <owner/repo> --priority <priority> --title <title> --body-file <file> [--label <label> ...]"* ]]
    [[ "${output}" == *"there is no --status"* ]]
    [[ "${output}" == *"a bad call leaves no issue behind"* ]]
    [[ "${output}" == *"The body is checked for leaks"* ]]
    [[ "${output}" == *"A refused body exits 8"* ]]
    [[ "${output}" == *"and so are the title and each --label"* ]]

    run "${SCRIPT}" help body
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf body check --repo <owner/repo> --body-file <file|->"* ]]
    [[ "${output}" == *"and exits 8"* ]]
    [[ "${output}" == *"CFWF_PRIVATE_OWNERS"* ]]
    [[ "${output}" == *"There is no option to skip"*"the check."* ]]

    run "${SCRIPT}" help comment
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf comment add --repo <owner/repo> (--pr <n> | --issue <n>) --body-file <file|->"* ]]
    [[ "${output}" == *"cfwf comment edit --repo <owner/repo> --comment-id <id> (--issue-comment | --review-comment) --body-file <file|->"* ]]
}

@test "the workflow-status help states that --set does not read back, the fallback listing limit and the GraphQL exception" {
    run "${SCRIPT}" help workflow-status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"The fallback listing reads at most 10000 items."* ]]
    [[ "${output}" == *"does not"*"read the value back"* ]]
    [[ "${output}" == *"Do not poll or repeat the write"* ]]
    [[ "${output}" == *"read-only GraphQL query for the single item"* ]]
    [[ "${output}" == *"write uses native gh project commands"* ]]
}

@test "a command's --help prints its usage and exits 0 without calling gh" {
    run "${SCRIPT}" workflow-status --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf workflow-status --set"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "running with no arguments prints the usage to stderr and exits 2" {
    run "${SCRIPT}"
    [ "${status}" -eq 2 ]
    run bash -c '"$1" 2>&1 >/dev/null' _ "${SCRIPT}"
    [[ "${output}" == *"Usage: cfwf <command>"* ]]
    run bash -c '"$1" 2>/dev/null' _ "${SCRIPT}"
    [ -z "${output}" ]
}

@test "an unknown command exits 2 with the usage on stderr" {
    run bash -c '"$1" frobnicate 2>&1 >/dev/null; exit "${PIPESTATUS[0]}"' _ "${SCRIPT}"
    [[ "${output}" == *"unknown command (argument 1; its value is not shown)"* && "${output}" != *frobnicate* ]]
    [[ "${output}" == *"Usage: cfwf <command>"* ]]
    run "${SCRIPT}" frobnicate
    [ "${status}" -eq 2 ]
}

@test "workflow-status --set refuses Approved in an agent session (exit 10), in any case, with no gh call and nothing written" {
    local spelling
    for spelling in Approved approved APPROVED; do
        rm -f "${GH_LOG}"
        CLAUDECODE=1 run --separate-stderr "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "${spelling}"
        [ "${status}" -eq 10 ] || { echo "${spelling}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: workflow-status refused: only a human can move an item to Approved" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "workflow-status --set still sets every other status in an agent session" {
    local status_name
    for status_name in Development "Human Review"; do
        rm -f "${GH_LOG}"
        CLAUDECODE=1 run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "${status_name}"
        [ "${status}" -eq 0 ] || { echo "${status_name}: ${status} ${output}" >&2; return 1; }
        [[ "${output}" == *"Set https://github.com/${REPO}/issues/1346 to ${status_name}"* ]]
    done
}

@test "workflow-status --set still sets Approved outside an agent session, and with CLAUDECODE other than 1" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Set https://github.com/${REPO}/issues/1346 to Approved"* ]]
    CLAUDECODE=0 run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
}

@test "workflow-status help names the agent restriction and exit 10" {
    run "${SCRIPT}" workflow-status --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"In an AI agent session (CLAUDECODE=1), --set --status Approved is refused with exit 10"* ]]
}

@test "workflow-status without --set or --check exits 2" {
    run "${SCRIPT}" workflow-status --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"needs --set or --check"* ]]
}

@test "workflow-status rejects --set together with --check" {
    run "${SCRIPT}" workflow-status --set --check
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mutually exclusive"* ]]
}

@test "an unknown option and an option missing its value exit 2" {
    run "${SCRIPT}" workflow-status --set --bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown option (argument 3; its value is not shown)"* && "${output}" != *--bogus* ]]

    run "${SCRIPT}" workflow-status --set --repo
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--repo needs a value"* ]]
}

@test "the board ids and the URL are not options any more: they are derived from --repo and --status" {
    local flag
    for flag in --owner --project-number --project-id --field-id --option-id --url; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" value
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${output}" == *"unknown option (argument 9; its value is not shown)"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}
