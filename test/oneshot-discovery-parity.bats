#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# Golden parity cases for work discovery in the .NET rewrite (#252). test/fixtures/discovery-parity.json
# holds, for each case, what the shell function reads (the githubstatus.com summary body, the priorities
# feed's response to each attempt, the repository's collaborators) and what it must print and return.
# This file checks github_incident_open (lib/github-health), fetch_all_priorities and get_trusted_logins
# (lib/github) against it, and Credfeto.Orchestrator.Commands.Tests (src/) checks the tool against the
# same file, so a change to what either side prints fails that side's own suite until the fixture and
# the other side agree. A null body or response means that read fails.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PARITY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/discovery-parity.json"

# Prints the value at jq path $1 of the fixture as raw text, without a trailing newline.
_parity() {
    jq -j "$1" "${PARITY_FIXTURE}"
}

# Writes the value at jq path $1 to file $2 as raw text, or removes the file when it is null, so the
# read of that file fails.
_parity_file() {
    if jq -e "$1 == null" "${PARITY_FIXTURE}" > /dev/null; then
        rm -f "$2"
    else
        jq -j "$1" "${PARITY_FIXTURE}" > "$2"
    fi
}

@test "the GitHub health parity lists are lib/globals' lists (#252)" {
    [ "$(jq -c '.githubHealth.components' "${PARITY_FIXTURE}")" = "$(jq -cn '$ARGS.positional' --args "${GITHUB_HEALTH_COMPONENTS[@]}")" ]
    [ "$(jq -c '.githubHealth.seriousImpacts' "${PARITY_FIXTURE}")" = "$(jq -cn '$ARGS.positional' --args "${GITHUB_HEALTH_SERIOUS_IMPACTS[@]}")" ]
    [ "$(jq -c '.githubHealth.outageStatuses' "${PARITY_FIXTURE}")" = "$(jq -cn '$ARGS.positional' --args "${GITHUB_HEALTH_OUTAGE_STATUSES[@]}")" ]
}

@test "github_incident_open prints and returns the golden result for every GitHub health parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_DISCOVERY
    local count i name expected_status expected actual status failures=0
    count=$(jq '.githubHealth.cases | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    GITHUB_STATUS_URL="file://${TEST_TMP}/status.json"
    for ((i = 0; i < count; i++)); do
        name=$(_parity ".githubHealth.cases[${i}].name")
        expected_status=$(_parity ".githubHealth.cases[${i}].status")
        expected=$(_parity ".githubHealth.cases[${i}].output")
        _parity_file ".githubHealth.cases[${i}].body" "${TEST_TMP}/status.json"
        status=0
        actual=$(github_incident_open 2> /dev/null) || status=$?
        if [ "${status}" != "${expected_status}" ] || [ "${actual}" != "${expected}" ]; then
            printf 'GitHub health case %d (%s): expected %s %q, got %s %q\n' "${i}" "${name}" "${expected_status}" "${expected}" "${status}" "${actual}"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

# A curl stand-in serving the case's responses in order, one an attempt (resp.1, resp.2, ...): it
# records the URL it was asked for, and a missing response file fails the attempt as an unreachable
# host does.
make_parity_curl_stub() {
    make_stub_multiline curl \
        'n=$(cat "${TEST_TMP}/curl_count" 2> /dev/null || echo 0)' \
        'n=$((n + 1))' \
        'echo "${n}" > "${TEST_TMP}/curl_count"' \
        'printf "%s\n" "${@: -1}" >> "${TEST_TMP}/curl_urls"' \
        '[ -f "${TEST_TMP}/resp.${n}" ] || exit 7' \
        'cat "${TEST_TMP}/resp.${n}"'
}

@test "fetch_all_priorities prints and returns the golden result for every priorities parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_DISCOVERY
    local count i j responses name user expected_status expected expected_url expected_requests actual status failures=0
    make_parity_curl_stub
    make_stub gh 'exit 1'
    PRIORITIES_URL=$(_parity .priorityFeedUrl)
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    count=$(jq '.priorities | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        name=$(_parity ".priorities[${i}].name")
        user=$(_parity ".priorities[${i}].user // \"\"")
        PRIORITIES_FETCH_RETRY_ATTEMPTS=$(_parity ".priorities[${i}].attempts")
        expected_status=$(_parity ".priorities[${i}].status")
        expected=$(_parity ".priorities[${i}].output")
        expected_url=$(_parity ".priorities[${i}].url")
        expected_requests=$(_parity ".priorities[${i}].requests")
        rm -f "${TEST_TMP}"/resp.* "${TEST_TMP}/curl_count" "${TEST_TMP}/curl_urls"
        responses=$(jq '.priorities['"${i}"'].responses | length' "${PARITY_FIXTURE}")
        for ((j = 0; j < responses; j++)); do
            _parity_file ".priorities[${i}].responses[${j}]" "${TEST_TMP}/resp.$((j + 1))"
        done
        _GH_ME="${user}"
        status=0
        actual=$(fetch_all_priorities 2> /dev/null) || status=$?
        if [ "${status}" != "${expected_status}" ] || [ "${actual}" != "${expected}" ] \
            || [ "$(sort -u "${TEST_TMP}/curl_urls")" != "${expected_url}" ] \
            || [ "$(cat "${TEST_TMP}/curl_count")" != "${expected_requests}" ]; then
            printf 'priorities case %d (%s): expected %s %q from %s requests of %s, got %s %q from %s requests of %s\n' \
                "${i}" "${name}" "${expected_status}" "${expected}" "${expected_requests}" "${expected_url}" \
                "${status}" "${actual}" "$(cat "${TEST_TMP}/curl_count")" "$(sort -u "${TEST_TMP}/curl_urls")"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

# A gh stand-in for the collaborators read: it fails the first ${TEST_TMP}/gh_failures calls, then
# prints ${TEST_TMP}/collaborators, one login a line, as gh's --jq '.[].login' does.
make_parity_collaborators_stub() {
    make_stub_multiline gh \
        'n=$(cat "${TEST_TMP}/gh_count" 2> /dev/null || echo 0)' \
        'n=$((n + 1))' \
        'echo "${n}" > "${TEST_TMP}/gh_count"' \
        'printf "%s\n" "$*" >> "${TEST_TMP}/gh_calls"' \
        '[ "${n}" -gt "$(cat "${TEST_TMP}/gh_failures")" ] || exit 1' \
        'cat "${TEST_TMP}/collaborators"'
}

@test "get_trusted_logins prints and returns the golden result for every trusted logins parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_DISCOVERY
    local count i name expected_status expected expected_requests actual status failures=0
    make_parity_collaborators_stub
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    count=$(jq '.trustedLogins | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        name=$(_parity ".trustedLogins[${i}].name")
        REPO_FULL=$(_parity ".trustedLogins[${i}].repo")
        OWNER=$(_parity ".trustedLogins[${i}].owner")
        WHITELISTED_USERS=$(_parity ".trustedLogins[${i}].whitelist")
        PR_CREATOR_LOGIN=$(_parity ".trustedLogins[${i}].creator")
        GH_COLLABORATORS_RETRY_ATTEMPTS=$(_parity ".trustedLogins[${i}].attempts")
        expected_status=$(_parity ".trustedLogins[${i}].status")
        expected=$(_parity ".trustedLogins[${i}].output")
        expected_requests=$(_parity ".trustedLogins[${i}].requests")
        _parity ".trustedLogins[${i}].failures" > "${TEST_TMP}/gh_failures"
        jq -r ".trustedLogins[${i}].collaborators[]" "${PARITY_FIXTURE}" > "${TEST_TMP}/collaborators"
        rm -f "${TEST_TMP}/gh_count" "${TEST_TMP}/gh_calls"
        _TRUSTED_LOGINS_JSON=""
        status=0
        actual=$(get_trusted_logins 2> /dev/null) || status=$?
        if [ "${status}" != "${expected_status}" ] || [ "${actual}" != "${expected}" ] \
            || [ "$(cat "${TEST_TMP}/gh_count")" != "${expected_requests}" ] \
            || [ "$(sort -u "${TEST_TMP}/gh_calls")" != "api repos/${REPO_FULL}/collaborators --paginate --jq .[].login" ]; then
            printf 'trusted logins case %d (%s): expected %s %q from %s reads, got %s %q from %s reads\n' \
                "${i}" "${name}" "${expected_status}" "${expected}" "${expected_requests}" \
                "${status}" "${actual}" "$(cat "${TEST_TMP}/gh_count")"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}
