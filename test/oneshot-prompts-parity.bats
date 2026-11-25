#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the lib/prompts builders in the .NET rewrite (#252). test/fixtures/prompts-parity.json
# and test/fixtures/prompts-pr-parity.json (the pull request CLAUDE.md cases, kept apart to stay under the commit
# hook's file size cap) hold, for each case, the tool's prompt kind, the name=value records lib/prompts sends it and
# exactly what the shell function prints for them. This file checks the shell functions against them, and
# Credfeto.Orchestrator.Commands.Tests (src/) checks the .NET port against the same files, so a change to either
# side's text fails that side's own suite until the fixture and the other side agree. A case marked "refuses" is one
# the tool must refuse, so the shell builds it; it still prints the golden text with the switch on.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PROMPTS_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/prompts-parity.json"
PROMPTS_PR_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/prompts-pr-parity.json"

# Reads one case's name=value records (each ended by a NUL byte) on stdin and calls the lib/prompts function for
# kind $1 with them, setting the lib/globals values the records carry: the same mapping the tool's records follow.
# REPO_WORK_DIR is emptied so an empty repo-path stays empty, as the tool reads it.
_prompt_parity_call() {
    local kind="$1" record
    local -A r=()
    local -a statuses=()
    while IFS= read -r -d '' record; do
        if [ "${record%%=*}" = wf-status ]; then
            statuses+=("${record#*=}")
        else
            r["${record%%=*}"]="${record#*=}"
        fi
    done
    REPO_WORK_DIR=""
    REPO_FULL="${r["repo-full"]-}"
    _WF_PROJECT_ID=""
    if [ "${r["board"]-}" = true ]; then
        _WF_PROJECT_ID=PVT_parity
    fi
    _WF_STATUS_ORDER=("${statuses[@]}")
    case "${kind}" in
        issue-claude-md)
            build_issue_claude_md "${r["item"]}" "${r["ai-instructions"]}" "${r["repo-path"]}" "${r["plan-approved"]}" \
                "${r["trusted-logins"]}" "${r["dirty-branch"]}" "${r["stale-branch"]}" "${r["background-stall"]}" \
                "${r["precheck-section"]}"
            ;;
        pr-claude-md)
            ROUND_MARKER_SIMPLIFY="${r["round-marker-simplify"]}"
            ROUND_MARKER_CODE_REVIEW="${r["round-marker-code-review"]}"
            ROUND_MARKER_SECURITY_REVIEW="${r["round-marker-security-review"]}"
            ROUND_MARKER_COVERAGE="${r["round-marker-coverage"]}"
            REVIEW_RESULT_CLEAN_MARKER="${r["review-result-clean-marker"]}"
            REVIEW_RESULT_FINDINGS_MARKER="${r["review-result-findings-marker"]}"
            MAX_SIMPLIFY_ITERATIONS="${r["max-simplify-iterations"]}"
            SIMPLIFY_THRASH_LIMIT="${r["simplify-thrash-limit"]}"
            MAX_CODE_REVIEW_ITERATIONS="${r["max-code-review-iterations"]}"
            MAX_SECURITY_REVIEW_ITERATIONS="${r["max-security-review-iterations"]}"
            MAX_COVERAGE_ITERATIONS="${r["max-coverage-iterations"]}"
            MIN_REVIEW_CONVERGENCE_ROUNDS="${r["min-review-convergence-rounds"]}"
            build_pr_claude_md "${r["item"]}" "${r["ai-instructions"]}" "${r["merge-state"]}" "${r["branch"]}" \
                "${r["repo-path"]}" "${r["dirty-branch"]}" "${r["dependency-pr"]}" "${r["trusted-logins"]}" \
                "${r["background-stall"]}" "${r["unaddressed-comments"]}" "${r["next-phase"]}" "${r["precheck-section"]}" \
                "${r["dependency-branch"]}"
            ;;
        issue-launch)
            build_issue_prompt "${r["item"]}" unused "${r["repo-path"]}"
            ;;
        pr-launch)
            build_pr_prompt "${r["item"]}" unused unused unused "${r["repo-path"]}"
            ;;
        precheck-section)
            PRECHECK_SUMMARY_LINES="${r["precheck-summary-lines"]}"
            PRECHECK_TIMEOUT_MINUTES="${r["precheck-timeout-minutes"]}"
            build_precheck_section "${r["kind"]}" "${r["sha"]}" "${r["status"]}" "${r["summary"]}" "${r["error"]}" \
                "${r["container-log"]}"
            ;;
    esac
}

# Runs every case of collection $1 in fixture $2 through its lib/prompts function, as the caller has set
# ORCHESTRATOR_DOTNET_PROMPTS, and prints one line for each case whose output differs from the golden text, byte
# for byte (trailing newlines included). Switched on, it also checks that the tool built exactly the cases not marked
# "refuses" (lib/prompts warns when it builds a case in bash instead). Returns 1 when any case differs or the
# collection is empty.
_check_prompt_parity_cases() {
    local collection="$1" fixture="$2" count index name kind tool built expected actual failures=0
    count=$(jq --arg c "${collection}" '.[$c] | length' "${fixture}")
    [ "${count}" -gt 0 ] || return 1
    for ((index = 0; index < count; index++)); do
        name=$(jq -r --arg c "${collection}" --argjson i "${index}" '.[$c][$i].name' "${fixture}")
        kind=$(jq -r --arg c "${collection}" --argjson i "${index}" '.[$c][$i].kind' "${fixture}")
        expected=$(
            jq -j --arg c "${collection}" --argjson i "${index}" '.[$c][$i].expected' "${fixture}"
            printf x
        )
        actual=$(
            jq -j --arg c "${collection}" --argjson i "${index}" \
                '.[$c][$i].records | to_entries[] | .key as $k | (.value | if type == "array" then .[] else . end) | "\($k)=\(.)\u0000"' \
                "${fixture}" | _prompt_parity_call "${kind}" 2> "${BATS_TEST_TMPDIR}/prompt-stderr"
            printf x
        )
        if [ "${actual}" != "${expected}" ]; then
            printf '%s case %d (%s): the output differs\n' "${collection}" "${index}" "${name}"
            failures=$((failures + 1))
        fi
        if [ "${ORCHESTRATOR_DOTNET_PROMPTS}" = 1 ]; then
            tool=$(jq -r --arg c "${collection}" --argjson i "${index}" '.[$c][$i].tool' "${fixture}")
            built=builds
            if grep -q 'building it in bash instead' "${BATS_TEST_TMPDIR}/prompt-stderr"; then
                built=refuses
            fi
            if [ "${built}" != "${tool}" ]; then
                printf '%s case %d (%s): the tool %s it, not %s\n' "${collection}" "${index}" "${name}" "${built}" "${tool}"
                failures=$((failures + 1))
            fi
        fi
    done
    [ "${failures}" -eq 0 ]
}

# Runs every check-length case through prompt_exceeds_max_chars in its locale with its MAX_PROMPT_CHARS, as the
# caller has set ORCHESTRATOR_DOTNET_PROMPTS, and prints one line for each case whose length or verdict differs.
_check_prompt_length_cases() {
    local name locale max encoded length too_long prompt actual expected failures=0 count=0
    # Unit-separated, not tab-separated: an empty field (the empty prompt) must not collapse into the next one
    while IFS=$'\x1f' read -r name locale max encoded length too_long; do
        count=$((count + 1))
        prompt=$(
            printf '%s' "${encoded}" | base64 -d
            printf x
        )
        actual=$(
            export LC_ALL="${locale}"
            MAX_PROMPT_CHARS="${max}"
            if prompt_exceeds_max_chars "${prompt%x}" 2> "${BATS_TEST_TMPDIR}/length-stderr"; then
                printf 'too long'
            else
                printf 'fits'
            fi
        )
        expected="${length}"$'\n'"fits"
        [ "${too_long}" = true ] && expected="${length}"$'\n'"too long"
        if [ "${actual}" != "${expected}" ]; then
            printf 'check-length case (%s): expected %s, got %s\n' "${name}" "${expected}" "${actual}"
            failures=$((failures + 1))
        fi
        if grep -q 'counting the prompt in bash instead' "${BATS_TEST_TMPDIR}/length-stderr"; then
            printf 'check-length case (%s): the tool failed\n' "${name}"
            failures=$((failures + 1))
        fi
    done < <(jq -r '.checkLength[] | [.name, .locale, .max, .promptBase64, .length, (.tooLong | tostring)] | join("\u001f")' "${PROMPTS_FIXTURE}")
    [ "${count}" -gt 0 ] && [ "${failures}" -eq 0 ]
}

# Every collection, switch off or on as the caller has set it.
_check_every_prompt_parity_case() {
    local failures=0
    _check_prompt_parity_cases issueClaudeMd "${PROMPTS_FIXTURE}" || failures=1
    _check_prompt_parity_cases pullRequestClaudeMd "${PROMPTS_PR_FIXTURE}" || failures=1
    _check_prompt_parity_cases launchPrompts "${PROMPTS_FIXTURE}" || failures=1
    _check_prompt_parity_cases precheckSections "${PROMPTS_FIXTURE}" || failures=1
    _check_prompt_length_cases || failures=1
    [ "${failures}" -eq 0 ]
}

@test "the lib/prompts builders print the golden text for every prompt parity case (#252)" {
    ORCHESTRATOR_DOTNET_PROMPTS=0
    run _check_every_prompt_parity_case
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool,
# given as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd).
# Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every prompt parity case prints the golden text through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    ORCHESTRATOR_DOTNET_PROMPTS=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    run _check_every_prompt_parity_case
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

@test "the prompt parity fixtures stay under the commit hook's 500 KB file size cap (#252)" {
    local fixture
    for fixture in "${PROMPTS_FIXTURE}" "${PROMPTS_PR_FIXTURE}"; do
        [ "$(wc -c < "${fixture}")" -lt $((500 * 1024)) ]
    done
}
