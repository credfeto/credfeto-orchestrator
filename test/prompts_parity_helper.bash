#!/usr/bin/env bash
# shellcheck shell=bash
#
# The mapping from a prompt parity case to its lib/prompts builder (#252), shared by test/oneshot-prompts-parity.bats,
# which checks the builders against test/fixtures/prompts-parity.json and prompts-pr-parity.json, and by
# scripts/prompts/regenerate, which writes those files from the builders, so both read a case the same way.

# Reads one case's name=value records (each ended by a NUL byte) on stdin and calls the lib/prompts function for
# kind $1 with them, setting the lib/globals values the records carry: the same mapping the tool's records follow.
# REPO_WORK_DIR is emptied so an empty repo-path stays empty, as the tool reads it.
# shellcheck disable=SC2034  # the globals set here are read by the lib/prompts builders
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
