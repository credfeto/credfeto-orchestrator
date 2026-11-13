#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the .NET rewrite (#252). test/fixtures/fingerprint-parity.json holds the
# fingerprint every case must produce. This file checks the shell functions in lib/fingerprints
# against it, and Credfeto.Orchestrator.Fingerprints.Tests (src/) checks the .NET port against the
# same file, so a change to what either side hashes fails that side's own suite until the fixture
# and the other side are updated to match. An "expected" of null means the function must fail.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PARITY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/fingerprint-parity.json"

# Prints field $3 of case $2 in collection $1: a string field raw, anything else as compact JSON,
# and nothing when the case does not have the field.
_parity_field() {
    jq -r --arg c "$1" --argjson i "$2" --arg f "$3" \
        '.[$c][$i] | if has($f) then (.[$f] | if type == "string" then . else tojson end) else empty end' \
        "${PARITY_FIXTURE}"
}

# Prints the item JSON for case $2 in collection $1: its text field ($3) verbatim when it has one,
# otherwise its JSON field ($4) re-serialised.
_parity_item() {
    local text
    text=$(_parity_field "$1" "$2" "$3")
    if [ -n "${text}" ] || jq -e --arg c "$1" --argjson i "$2" --arg f "$3" '.[$c][$i] | has($f)' "${PARITY_FIXTURE}" > /dev/null; then
        printf '%s' "${text}"
    else
        _parity_field "$1" "$2" "$4"
    fi
}

# Prints the optional JSON input $3 of case $2 in collection $1: its raw text form ($3Text) when
# present, otherwise the JSON value, otherwise nothing (so the function takes its default).
_parity_optional_json() {
    local text
    text=$(_parity_field "$1" "$2" "$3Text")
    if [ -n "${text}" ]; then
        printf '%s' "${text}"
    else
        _parity_field "$1" "$2" "$3"
    fi
}

@test "fingerprint_pr_json produces the golden fingerprint for every pull request parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_FINGERPRINTS
    local count i name pr trusted review_comments expected actual failures=0
    count=$(jq '.pullRequests | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        name=$(_parity_field pullRequests "${i}" name)
        pr=$(_parity_item pullRequests "${i}" prText pr)
        trusted=$(_parity_optional_json pullRequests "${i}" trusted)
        review_comments=$(_parity_optional_json pullRequests "${i}" reviewComments)
        expected=$(_parity_field pullRequests "${i}" expected)
        actual=$(fingerprint_pr_json "${pr}" "${trusted}" "${review_comments}" 2> /dev/null) || actual=null
        if [ "${actual}" != "${expected}" ]; then
            printf 'pull request case %d (%s): expected %s, got %s\n' "${i}" "${name}" "${expected}" "${actual}"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

@test "fingerprint_issue_json produces the golden fingerprint for every issue parity case (#252)" {
    unset ORCHESTRATOR_DOTNET_FINGERPRINTS
    local count i name issue trusted plan_approved expected actual failures=0
    count=$(jq '.issues | length' "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ]
    for ((i = 0; i < count; i++)); do
        name=$(_parity_field issues "${i}" name)
        issue=$(_parity_item issues "${i}" issueText issue)
        trusted=$(_parity_optional_json issues "${i}" trusted)
        plan_approved=$(_parity_field issues "${i}" planApproved)
        expected=$(_parity_field issues "${i}" expected)
        actual=$(fingerprint_issue_json "${issue}" "${trusted}" "${plan_approved}" 2> /dev/null) || actual=null
        if [ "${actual}" != "${expected}" ]; then
            printf 'issue case %d (%s): expected %s, got %s\n' "${i}" "${name}" "${expected}" "${actual}"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

@test "the parity fixture's fingerprints carry the current FINGERPRINT_SCHEMA_VERSION (#252)" {
    run jq -r --arg v "${FINGERPRINT_SCHEMA_VERSION}" \
        '[.pullRequests[], .issues[] | .expected | select(. != null) | select(startswith($v + ":") | not)] | length' \
        "${PARITY_FIXTURE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}
