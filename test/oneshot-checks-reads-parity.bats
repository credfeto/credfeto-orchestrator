#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# Golden parity cases for the CHECKS reads that ask GitHub (#252). test/fixtures/checks-reads-parity.json holds, for
# each case, the gh response fetch_pr_required_check_names or head_commit_has_running_check_runs (lib/github) reads,
# the cfwf MCP server result the tool reads, what the tool does with it, and what the shell function prints or
# returns. This file checks the shell functions against it with ORCHESTRATOR_DOTNET_CHECKS off, and with it on and a
# stand-in tool that does what the case says, so a tool that fails or refuses leaves the shell's answer as it is.
# Credfeto.Orchestrator.Commands.Tests (src/) checks the tool itself against the same file.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PARITY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/checks-reads-parity.json"

# Prints case $2 of collection $1 as one line of JSON
_case_json() {
    jq -c --arg c "$1" --argjson i "$2" '.[$c][$i]' "${PARITY_FIXTURE}"
}

# Prints field $2 of the case JSON $1 as text, or "null" when it is null
_case_field() {
    jq -r --arg f "$2" '.[$f] // "null"' <<< "$1"
}

# A gh stand-in: api graphql prints graphql.json; the check-runs endpoint applies its --jq filter to runs.json, which
# holds one JSON text a page, as gh --paginate --jq filters each page. A missing file fails the call, and every call
# is logged to gh_calls, one a line.
make_reads_gh_stub() {
    make_stub_multiline gh \
        'printf "%s\n" "$*" >> "${TEST_TMP}/gh_calls"' \
        'case "$*" in' \
        '    "api graphql "*) [ -f "${TEST_TMP}/graphql.json" ] || exit 1; cat "${TEST_TMP}/graphql.json" ;;' \
        '    "api --paginate repos/"*"/check-runs?per_page=100 --jq "*) [ -f "${TEST_TMP}/runs.json" ] || exit 1; jq -r "${@: -1}" "${TEST_TMP}/runs.json" ;;' \
        '    *) exit 1 ;;' \
        'esac'
}

# A stand-in for the tool: logs its arguments to cmd_args (one a line) and ORCHESTRATOR_CFWF_MCP_URL to mcp_url,
# prints ${TEST_TMP}/answer and exits with ${TEST_TMP}/status
make_reads_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        'printf "%s\n" "$@" >> "${TEST_TMP}/cmd_args"' \
        'printf "%s" "${ORCHESTRATOR_CFWF_MCP_URL:-unset}" > "${TEST_TMP}/mcp_url"' \
        'printf "tool stderr\n" >&2' \
        'cat "${TEST_TMP}/answer"' \
        'exit "$(cat "${TEST_TMP}/status")"'
    export ORCHESTRATOR_CMD=fake-orchestrator
    ORCHESTRATOR_CFWF_MCP_URL=https://mcp.example.test/mcp
}

# Serves the case's gh response ($1) from $2, one JSON text a page when $3 is "pages", or removes $2 when the
# response is null, so that call fails; clears the call logs
_serve_case() {
    rm -f "$2" "${TEST_TMP}/gh_calls" "${TEST_TMP}/cmd_args"
    if [ "$(jq '.gh == null' <<< "$1")" = false ]; then
        if [ "${3:-}" = pages ]; then
            jq -c '.gh[]' <<< "$1" > "$2"
        else
            jq -c '.gh' <<< "$1" > "$2"
        fi
    fi
}

# Has the stand-in tool do what required-names case $1 says: print the expected line, fail with 1 or refuse with 3
_required_tool_does() {
    case "$(_case_field "$1" tool)" in
        answers)
            printf '%s\n' "$(_case_field "$1" expected)" > "${TEST_TMP}/answer"
            printf '0' > "${TEST_TMP}/status"
            ;;
        fails)
            printf 'should not be used\n' > "${TEST_TMP}/answer"
            printf '1' > "${TEST_TMP}/status"
            ;;
        *)
            printf 'should not be used\n' > "${TEST_TMP}/answer"
            printf '3' > "${TEST_TMP}/status"
            ;;
    esac
}

# Checks fetch_pr_required_check_names against every required-names case; with $1 "on", through the stand-in tool
_check_required_cases() {
    local mode="${1:-off}" count i item name repo pr expected actual tool failures=0
    make_reads_gh_stub
    make_reads_cmd_stub
    count=$(jq '.requiredCheckNames | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        item=$(_case_json requiredCheckNames "${i}")
        name=$(_case_field "${item}" name)
        repo=$(_case_field "${item}" repo)
        pr=$(_case_field "${item}" pr)
        tool=$(_case_field "${item}" tool)
        expected=$(_case_field "${item}" expected)
        _serve_case "${item}" "${TEST_TMP}/graphql.json"
        _required_tool_does "${item}"
        actual=$(fetch_pr_required_check_names "${pr}" "${repo}" 2> "${TEST_TMP}/stderr") || actual=null
        if [ "${actual}" != "${expected}" ]; then
            printf 'required names case %d (%s): expected %s, got %s\n' "${i}" "${name}" "${expected}" "${actual}"
            failures=$((failures + 1))
        fi
        if [ "${mode}" = off ] || [ "${tool}" != answers ]; then
            if ! grep -qF -- "-f owner=${repo%%/*} -f name=${repo#*/} -F number=${pr}" "${TEST_TMP}/gh_calls"; then
                printf 'required names case %d (%s): gh was not asked for %s#%s\n' "${i}" "${name}" "${repo}" "${pr}"
                failures=$((failures + 1))
            fi
        elif [ -e "${TEST_TMP}/gh_calls" ] || [ -s "${TEST_TMP}/stderr" ]; then
            printf 'required names case %d (%s): the tool answered, but gh was asked or a warning given\n' "${i}" "${name}"
            failures=$((failures + 1))
        fi
        if [ "${mode}" = off ] && [ -e "${TEST_TMP}/cmd_args" ]; then
            printf 'required names case %d (%s): the tool was asked with the switch off\n' "${i}" "${name}"
            failures=$((failures + 1))
        fi
        if [ "${mode}" = on ] && [ "$(paste -sd '|' "${TEST_TMP}/cmd_args")" != "checks|required-check-names|--repo|${repo}|--pr|${pr}" ]; then
            printf 'required names case %d (%s): the tool was asked %s\n' "${i}" "${name}" "$(paste -sd '|' "${TEST_TMP}/cmd_args")"
            failures=$((failures + 1))
        fi
        if [ "${mode}" = on ] && [ "${tool}" != answers ] \
            && ! grep -qx "! fake-orchestrator checks required-check-names failed (exit [13]); answering it in bash instead" "${TEST_TMP}/stderr"; then
            printf 'required names case %d (%s): no fallback warning: %s\n' "${i}" "${name}" "$(cat "${TEST_TMP}/stderr")"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

# Checks head_commit_has_running_check_runs against every check-run case; with $1 "on", through the stand-in tool,
# which exits with the case's toolStatus
_check_running_cases() {
    local mode="${1:-off}" count i item name repo sha expected tool_status actual failures=0
    make_reads_gh_stub
    make_reads_cmd_stub
    printf '' > "${TEST_TMP}/answer"
    count=$(jq '.headCommitRunningCheckRuns | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        item=$(_case_json headCommitRunningCheckRuns "${i}")
        name=$(_case_field "${item}" name)
        repo=$(jq -r .repo <<< "${item}")
        sha=$(jq -r .sha <<< "${item}")
        expected=$(_case_field "${item}" expected)
        tool_status=$(_case_field "${item}" toolStatus)
        _serve_case "${item}" "${TEST_TMP}/runs.json" pages
        printf '%s' "${tool_status}" > "${TEST_TMP}/status"
        actual=0
        head_commit_has_running_check_runs "${repo}" "${sha}" 2> "${TEST_TMP}/stderr" || actual=$?
        if [ "${actual}" != "${expected}" ]; then
            printf 'check run case %d (%s): expected %s, got %s\n' "${i}" "${name}" "${expected}" "${actual}"
            failures=$((failures + 1))
        fi
        if [ -z "${repo}" ] || [ -z "${sha}" ]; then
            if [ -e "${TEST_TMP}/gh_calls" ] || [ -e "${TEST_TMP}/cmd_args" ]; then
                printf 'check run case %d (%s): asked without a repository and a commit\n' "${i}" "${name}"
                failures=$((failures + 1))
            fi
        elif [ "${mode}" = off ] || [ "${tool_status}" = 3 ]; then
            if [ "$(cat "${TEST_TMP}/gh_calls")" != "api --paginate repos/${repo}/commits/${sha}/check-runs?per_page=100 --jq .check_runs[] | select(.conclusion == null) | .status" ]; then
                printf 'check run case %d (%s): gh was asked %s\n' "${i}" "${name}" "$(cat "${TEST_TMP}/gh_calls")"
                failures=$((failures + 1))
            fi
        elif [ -e "${TEST_TMP}/gh_calls" ] || [ -s "${TEST_TMP}/stderr" ]; then
            printf 'check run case %d (%s): the tool answered, but gh was asked or a warning given\n' "${i}" "${name}"
            failures=$((failures + 1))
        fi
        if [ "${mode}" = off ] && [ -e "${TEST_TMP}/cmd_args" ]; then
            printf 'check run case %d (%s): the tool was asked with the switch off\n' "${i}" "${name}"
            failures=$((failures + 1))
        fi
        if [ "${mode}" = on ] && [ -n "${repo}" ] && [ -n "${sha}" ] \
            && [ "$(paste -sd '|' "${TEST_TMP}/cmd_args")" != "checks|has-running-check-runs|--repo|${repo}|--sha|${sha}" ]; then
            printf 'check run case %d (%s): the tool was asked %s\n' "${i}" "${name}" "$(paste -sd '|' "${TEST_TMP}/cmd_args")"
            failures=$((failures + 1))
        fi
        if [ "${mode}" = on ] && [ "${tool_status}" = 3 ] && [ -n "${repo}" ] && [ -n "${sha}" ] \
            && ! grep -qx "! fake-orchestrator checks has-running-check-runs failed (exit 3); answering it in bash instead" "${TEST_TMP}/stderr"; then
            printf 'check run case %d (%s): no fallback warning: %s\n' "${i}" "${name}" "$(cat "${TEST_TMP}/stderr")"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

@test "fetch_pr_required_check_names prints the golden names for every required check parity case (#252)" {
    ORCHESTRATOR_DOTNET_CHECKS=0
    _check_required_cases off
}

@test "with ORCHESTRATOR_DOTNET_CHECKS on, fetch_pr_required_check_names prints the same for every case (#252)" {
    ORCHESTRATOR_DOTNET_CHECKS=1
    _check_required_cases on
    [ "$(cat "${TEST_TMP}/mcp_url")" = "https://mcp.example.test/mcp" ]
}

@test "head_commit_has_running_check_runs returns the golden status for every check run parity case (#252)" {
    ORCHESTRATOR_DOTNET_CHECKS=0
    _check_running_cases off
}

@test "with ORCHESTRATOR_DOTNET_CHECKS on, head_commit_has_running_check_runs returns the same for every case (#252)" {
    ORCHESTRATOR_DOTNET_CHECKS=1
    _check_running_cases on
    [ "$(cat "${TEST_TMP}/mcp_url")" = "https://mcp.example.test/mcp" ]
}

@test "every checks reads parity case gives the tool a cfwf MCP result or a failure, never both, and is consistent (#252)" {
    run jq -r '[(.requiredCheckNames[], .headCommitRunningCheckRuns[]) | select(has("mcp") == has("mcpError"))] | length' "${PARITY_FIXTURE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
    run jq -r '[.requiredCheckNames[] | select(.tool | IN("answers", "fails", "refuses") | not)] | length' "${PARITY_FIXTURE}"
    [ "${output}" = "0" ]
    # The tool answers only where the shell has an answer, and a failing tool's 1 is the shell's own failure
    run jq -r '[.requiredCheckNames[] | select(.tool == "answers" and .expected == null)] | length' "${PARITY_FIXTURE}"
    [ "${output}" = "0" ]
    # A check-run status the tool gives is the shell's, unless it refuses
    run jq -r '[.headCommitRunningCheckRuns[] | select(.toolStatus != 3 and .toolStatus != .expected)] | length' "${PARITY_FIXTURE}"
    [ "${output}" = "0" ]
    run jq -r '[.headCommitRunningCheckRuns[] | select(.toolStatus == 3)] | length' "${PARITY_FIXTURE}"
    [ "${output}" -ge 1 ]
    run jq -r '[.requiredCheckNames[] | select(.tool == "refuses")] | length' "${PARITY_FIXTURE}"
    [ "${output}" -ge 1 ]
}
