#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the lib/github-status predicates in the .NET rewrite (#252).
# test/fixtures/predicates-parity.json holds, for each case, the shell function, its arguments and what
# it must print and return (0, or 1 for any failure). This file checks the shell functions against it,
# and Credfeto.Orchestrator.Predicates.Tests (src/) checks the .NET port against the same file, so a
# change to what either side answers fails that side's own suite until the fixture and the other side
# agree. An argument that is a JSON string is passed as its text, any other JSON value as jq -c prints
# it. The plan-approval cases are the human gate on implementation plans: never loosen one to make the
# other side pass.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PARITY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/predicates-parity.json"

# Runs every case through its shell function, as the caller has set ORCHESTRATOR_DOTNET_PREDICATES, and
# prints one line for each case whose status or output differs from the golden one. Returns 1 when any
# case differs.
_check_predicate_parity_cases() {
    local index fn per encoded expected_status expected_output result status output arg failures=0 count=0
    local default_per="${PR_UNADDRESSED_COMMENT_MAX_CHARS}"
    local -a args
    while IFS=$'\t' read -r index fn per encoded expected_status expected_output; do
        args=()
        for arg in ${encoded}; do
            if [ "${arg}" = "-" ]; then
                args+=("")
            else
                arg=$(
                    printf '%s' "${arg}" | base64 -d
                    printf x
                )
                args+=("${arg%x}")
            fi
        done
        if [ "${expected_output}" = "-" ]; then
            expected_output=""
        else
            expected_output=$(
                printf '%s' "${expected_output}" | base64 -d
                printf x
            )
            expected_output="${expected_output%x}"
        fi
        [ "${per}" = "-" ] && per="${default_per}"
        PR_UNADDRESSED_COMMENT_MAX_CHARS="${per}"
        result=$(
            "${fn}" "${args[@]}" 2> /dev/null
            printf '\001%d' "$?"
        )
        status="${result##*$'\001'}"
        output="${result%$'\001'*}"
        [ "${status}" -eq 0 ] || status=1
        if [ "${status}" != "${expected_status}" ] || [ "${output}" != "${expected_output}" ]; then
            printf 'case %d (%s): expected %s %q, got %s %q\n' "${index}" "${fn}" "${expected_status}" "${expected_output}" "${status}" "${output}"
            failures=$((failures + 1))
        fi
        count=$((count + 1))
    done < <(jq -r '.cases | to_entries[] | [
            (.key | tostring),
            .value.function,
            (.value.perCommentMax // "-" | tostring),
            (.value.args | map(if type == "string" then . else tojson end | if . == "" then "-" else @base64 end) | join(" ")),
            (.value.status | tostring),
            (.value.output | if . == "" then "-" else @base64 end)
        ] | @tsv' "${PARITY_FIXTURE}")
    PR_UNADDRESSED_COMMENT_MAX_CHARS="${default_per}"
    [ "${count}" -gt 0 ] && [ "${failures}" -eq 0 ]
}

@test "the predicate parity fixture's patterns, jq definitions and settings are lib/globals' (#252)" {
    local name
    for name in LOOSE_PLAN_HEADING_PATTERN APPROVAL_LINE_KEYWORD_PATTERN APPROVAL_NEGATION_PATTERN APPROVER_ASSOCIATIONS; do
        [ "$(jq -j --arg n "${name}" '.patterns[$n]' "${PARITY_FIXTURE}")" = "${!name}" ]
    done
    for name in _JQ_DEF_LATEST_CHECK_RUNS _JQ_DEF_CHECK_FAILED _JQ_DEF_COUNTED_LOGIN _JQ_DEF_AUTOMATED_SUMMARY; do
        [ "$(jq -j --arg n "${name}" '.definitions[$n]' "${PARITY_FIXTURE}")" = "${!name}" ]
    done
    [ "$(jq -j '.settings.PR_UNADDRESSED_COMMENT_MAX_CHARS' "${PARITY_FIXTURE}")" = "${PR_UNADDRESSED_COMMENT_MAX_CHARS}" ]
}

@test "the predicate parity fixture covers every ported lib/github-status function (#252)" {
    run jq -r '[.cases[].function] | unique | join(" ")' "${PARITY_FIXTURE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "annotate_pr_json_required_checks issue_json_has_human_plan_approval issue_json_has_plan_comment pr_json_env_block_image_sha pr_json_has_failed_check_of_unknown_requiredness pr_json_has_failed_required_check pr_json_has_only_passed_checks pr_json_has_pending_ci_checks pr_json_has_placeholder_file pr_json_has_unaddressed_review_request pr_json_has_unaddressed_trusted_comment pr_json_is_terminal pr_json_latest_trusted_comment_timestamp pr_json_lowest_closing_issue pr_json_needs_review_approval pr_json_unaddressed_trusted_comments_text" ]
}

@test "every lib/github-status predicate parity case gives the golden status and output (#252)" {
    unset ORCHESTRATOR_DOTNET_PREDICATES
    run _check_predicate_parity_cases
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

# The end-to-end run of the plan's test strategy: the same cases with the switch on and the freshly
# built tool, given as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of
# src/Credfeto.Orchestrator.Cmd). Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every predicate parity case gives the golden status and output through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    ORCHESTRATOR_DOTNET_PREDICATES=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    run _check_predicate_parity_cases
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}
