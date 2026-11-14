#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# Golden parity cases for the GitHub reads of the .NET rewrite (#252). test/fixtures/github-parity.json
# holds, for each case, the gh responses the shell function reads, the cfwf MCP server result the tool
# reads, and what both must print. This file checks the shell functions in lib/github against it, and
# Credfeto.Orchestrator.Commands.Tests (src/) checks the tool against the same file, so a change to what
# either side prints fails that side's own suite until the fixture and the other side agree. A null
# expected value means the function must fail; a null gh response means that gh call fails.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PARITY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/github-parity.json"

# Writes field $3 of case $2 in collection $1 to file $4 as compact JSON, or removes the file when the
# field is null, so the gh stub fails that call.
_parity_gh_response() {
    if jq -e --arg c "$1" --argjson i "$2" --arg f "$3" '.[$c][$i][$f] == null' "${PARITY_FIXTURE}" > /dev/null; then
        rm -f "$4"
    else
        jq -c --arg c "$1" --argjson i "$2" --arg f "$3" '.[$c][$i][$f]' "${PARITY_FIXTURE}" > "$4"
    fi
}

# Prints string field $3 of case $2 in collection $1, or "null" when it is null.
_parity_field() {
    jq -r --arg c "$1" --argjson i "$2" --arg f "$3" '.[$c][$i][$f] // "null"' "${PARITY_FIXTURE}"
}

# A gh stand-in serving the case's responses: pr list applies its --jq filter to pulls.json, as gh
# does, and the branch and rules endpoints print branch.json and rules.json. A missing file fails
# the call.
make_parity_gh_stub() {
    make_stub_multiline gh \
        'case "$*" in' \
        '    "pr list "*) [ -f "${TEST_TMP}/pulls.json" ] || exit 1; jq -r "${@: -1}" "${TEST_TMP}/pulls.json" ;;' \
        '    *"/rules/branches/"*) [ -f "${TEST_TMP}/rules.json" ] || exit 1; cat "${TEST_TMP}/rules.json" ;;' \
        '    *"/branches/"*) [ -f "${TEST_TMP}/branch.json" ] || exit 1; cat "${TEST_TMP}/branch.json" ;;' \
        '    *) exit 1 ;;' \
        'esac'
}

# Checks function $1 against field $2 of every openPullRequests case.
_check_open_pr_cases() {
    local function="$1" field="$2" count i name repo head expected actual failures=0
    make_parity_gh_stub
    count=$(jq '.openPullRequests | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        name=$(_parity_field openPullRequests "${i}" name)
        repo=$(_parity_field openPullRequests "${i}" repo)
        head=$(_parity_field openPullRequests "${i}" head)
        expected=$(_parity_field openPullRequests "${i}" "${field}")
        _parity_gh_response openPullRequests "${i}" gh "${TEST_TMP}/pulls.json"
        actual=$("${function}" "${repo}" "${head}" 2> /dev/null) || actual=null
        if [ "${actual}" != "${expected}" ]; then
            printf 'open pull request case %d (%s): expected %s, got %s\n' "${i}" "${name}" "${expected}" "${actual}"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

@test "fetch_open_pr_numbers_on_head prints the golden numbers for every open pull request parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_GITHUB
    _check_open_pr_cases fetch_open_pr_numbers_on_head numbers
}

@test "fetch_open_pr_count_on_head prints the golden count for every open pull request parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_GITHUB
    _check_open_pr_cases fetch_open_pr_count_on_head count
}

@test "fetch_branch_requires_status_checks prints the golden answer for every branch parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_GITHUB
    local count i name repo branch expected actual failures=0
    make_parity_gh_stub
    count=$(jq '.branchRequiresStatusChecks | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        name=$(_parity_field branchRequiresStatusChecks "${i}" name)
        repo=$(_parity_field branchRequiresStatusChecks "${i}" repo)
        branch=$(_parity_field branchRequiresStatusChecks "${i}" branch)
        expected=$(_parity_field branchRequiresStatusChecks "${i}" expected)
        _parity_gh_response branchRequiresStatusChecks "${i}" ghBranch "${TEST_TMP}/branch.json"
        _parity_gh_response branchRequiresStatusChecks "${i}" ghRules "${TEST_TMP}/rules.json"
        actual=$(fetch_branch_requires_status_checks "${branch}" "${repo}" 2> /dev/null) || actual=null
        if [ "${actual}" != "${expected}" ]; then
            printf 'branch case %d (%s): expected %s, got %s\n' "${i}" "${name}" "${expected}" "${actual}"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

@test "every parity case gives the tool either a cfwf MCP result or a failure, never both (#252)" {
    run jq -r '[.openPullRequests[], .branchRequiresStatusChecks[] | select(has("mcp") == has("mcpError"))] | length' "${PARITY_FIXTURE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}
