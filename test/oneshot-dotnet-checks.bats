#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_CHECKS (#252): off by default; when on, the lib/github-status routing and label reads and
# priority_for_labels (lib/workflow-board) ask ORCHESTRATOR_CMD checks, take its answer when it gives one (exit 0 or
# 1) and answer in bash, with a warning, when it does not. test/oneshot-checks-parity.bats checks what both sides
# print and return.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PR_JSON='{"reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":null,"labels":[{"name":"Blocked"}]}'

# A stand-in for the tool: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---) and its stdin to
# ${TEST_TMP}/cmd_stdin, writes "tool stderr" to stderr, prints ${TEST_TMP}/answer and exits with ${TEST_TMP}/status
# (0 when absent)
make_checks_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'cat >> "${TEST_TMP}/cmd_stdin"' \
        'printf "tool stderr\n" >&2' \
        'if [ -f "${TEST_TMP}/answer" ]; then cat "${TEST_TMP}/answer"; fi' \
        'if [ -f "${TEST_TMP}/status" ]; then exit "$(cat "${TEST_TMP}/status")"; fi' \
        'exit 0'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

_tool_answers() {
    printf '%s' "$1" > "${TEST_TMP}/answer"
    printf '%s' "$2" > "${TEST_TMP}/status"
}

# The arguments of the one call the stand-in got, joined by |
_cmd_call() {
    grep -v '^---$' "${TEST_TMP}/cmd_args" | paste -sd '|'
}

# Asks each function once, printing its output and status on one line
_ask_each() {
    local out status call
    local -a parts
    for call in \
        "pr_next_phase_for_board_status|AI Review|${PR_JSON}" \
        "pr_merge_state_allows_settled|${PR_JSON}|BEHIND" \
        "pr_session_progress_reason|AI Review|AI Coverage|||a|a" \
        "pr_clean_review_status_comment|AI Coverage" \
        "pr_json_has_blocked_label|${PR_JSON}" \
        "issue_json_has_blocked_label|${PR_JSON}" \
        "priority_for_labels|[{\"name\":\"High\"}]"; do
        IFS='|' read -r -a parts <<< "${call}"
        status=0
        out=$("${parts[@]}") || status=$?
        printf '%s:%s\n' "${status}" "${out}"
    done
}

@test "ORCHESTRATOR_DOTNET_CHECKS defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_CHECKS bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_CHECKS}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "the checks reads never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_CHECKS is off (#252)" {
    make_checks_cmd_stub
    ORCHESTRATOR_DOTNET_CHECKS=0

    run --separate-stderr _ask_each

    [ "${status}" -eq 0 ]
    [ "${output}" = "0:PHASE E (code review)
0:
0:board moved from AI Review to AI Coverage
0:Security review clean, advancing to coverage check (board moved by the orchestrator: the session reported no findings but did not move it)
0:
0:
0:High" ]
    [ ! -e "${TEST_TMP}/cmd_args" ]
}

@test "next-phase sends the board status, the required-checks flag and the PR JSON, and takes the tool's phase (#252)" {
    make_checks_cmd_stub
    ORCHESTRATOR_DOTNET_CHECKS=1
    _tool_answers "PHASE X (from the tool)" 0

    run --separate-stderr pr_next_phase_for_board_status "AI Review" "${PR_JSON}" true

    [ "${status}" -eq 0 ]
    [ "${output}" = "PHASE X (from the tool)" ]
    [ -z "${stderr}" ]
    [ "$(_cmd_call)" = "checks|next-phase|--board-status|AI Review|--required-checks-unknown|true" ]
    [ "$(cat "${TEST_TMP}/cmd_stdin")" = "${PR_JSON}" ]
}

@test "next-phase defaults the required-checks flag to false, and the tool's exit 1 is the function's no-phase 2 (#252)" {
    make_checks_cmd_stub
    ORCHESTRATOR_DOTNET_CHECKS=1
    _tool_answers "" 1

    run --separate-stderr pr_next_phase_for_board_status "AI Review" "${PR_JSON}"

    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [ "$(_cmd_call)" = "checks|next-phase|--board-status|AI Review|--required-checks-unknown|false" ]
}

@test "the yes-or-no checks reads return the tool's status (#252)" {
    make_checks_cmd_stub
    ORCHESTRATOR_DOTNET_CHECKS=1
    _tool_answers "" 1

    run pr_merge_state_allows_settled "${PR_JSON}" CLEAN
    [ "${status}" -eq 1 ]
    run pr_json_has_blocked_label "${PR_JSON}"
    [ "${status}" -eq 1 ]
    run issue_json_has_blocked_label "${PR_JSON}"
    [ "${status}" -eq 1 ]

    _tool_answers "" 0
    run pr_merge_state_allows_settled "${PR_JSON}" DIRTY
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^checks$' "${TEST_TMP}/cmd_args")" -eq 4 ]
    grep -qx -- '--merge-state' "${TEST_TMP}/cmd_args"
    grep -qx 'has-blocked-label' "${TEST_TMP}/cmd_args"
}

@test "session-progress-reason and clean-review-comment send their arguments as options and read no JSON (#252)" {
    make_checks_cmd_stub
    ORCHESTRATOR_DOTNET_CHECKS=1
    _tool_answers "from the tool" 0

    run --separate-stderr pr_session_progress_reason "AI Review" "AI Review" "2026-01-01T00:00:00Z" "" abc def

    [ "${status}" -eq 0 ]
    [ "${output}" = "from the tool" ]
    [ "$(_cmd_call)" = "checks|session-progress-reason|--pre-board|AI Review|--post-board|AI Review|--pre-comment-ts|2026-01-01T00:00:00Z|--post-comment-ts||--pre-head|abc|--post-head|def" ]

    rm "${TEST_TMP}/cmd_args"
    run --separate-stderr pr_clean_review_status_comment "AI Coverage"

    [ "${status}" -eq 0 ]
    [ "${output}" = "from the tool" ]
    [ "$(_cmd_call)" = "checks|clean-review-comment|--status|AI Coverage" ]
    [ -z "$(tr -d '\n' < "${TEST_TMP}/cmd_stdin")" ]
}

@test "priority_for_labels prints the tool's text as it is, trailing newline kept (#252)" {
    make_checks_cmd_stub
    ORCHESTRATOR_DOTNET_CHECKS=1
    _tool_answers $'Urgent\n' 0

    run priority_for_labels '[{"name":"urgent"}]'

    [ "${status}" -eq 0 ]
    [ "${output}" = "Urgent" ]
    local kept
    kept=$(
        priority_for_labels '[{"name":"urgent"}]'
        printf x
    )
    [ "${kept}" = $'Urgent\nx' ]
    [ "$(_cmd_call | cut -d'|' -f1-2)" = "checks|priority-for-labels" ]
}

@test "a tool that refuses, fails or is missing is warned about and the function answers in bash (#252)" {
    local code expected
    make_checks_cmd_stub
    expected=$(ORCHESTRATOR_DOTNET_CHECKS=0 _ask_each)
    ORCHESTRATOR_DOTNET_CHECKS=1
    for code in 3 2 125 127; do
        _tool_answers "should not be used" "${code}"

        run --separate-stderr _ask_each

        [ "${status}" -eq 0 ]
        [ "${output}" = "${expected}" ]
        [ "$(printf '%s\n' "${stderr}" | grep -c "^! fake-orchestrator checks .* failed (exit ${code}); answering it in bash instead$")" -eq 7 ]
        [[ "${stderr}" != *"tool stderr"* ]]
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr _ask_each
    [ "${output}" = "${expected}" ]
    [ "$(printf '%s\n' "${stderr}" | grep -c 'failed (exit 127); answering it in bash instead$')" -eq 7 ]
}

@test "a checks query the self-installed binary lacks is answered in bash, with no warning per call (#252)" {
    local expected
    make_checks_cmd_stub
    expected=$(ORCHESTRATOR_DOTNET_CHECKS=0 _ask_each)
    ORCHESTRATOR_DOTNET_CHECKS=1
    ORCHESTRATOR_CMD_CHECKED=1
    ORCHESTRATOR_CMD_CAPABILITIES=$'\npredicate pr-is-terminal\n'

    run --separate-stderr _ask_each

    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
    [ -z "${stderr}" ]
    [ ! -e "${TEST_TMP}/cmd_args" ]
}

@test "the checks area is gated by its own switch in the capability check (#252)" {
    ORCHESTRATOR_DOTNET_CHECKS=1
    run _orchestrator_cmd_area_on checks
    [ "${status}" -eq 0 ]
    ORCHESTRATOR_DOTNET_CHECKS=0
    run _orchestrator_cmd_area_on checks
    [ "${status}" -eq 1 ]
    grep -q '^checks next-phase$' "${REPO_ROOT}/src/Credfeto.Orchestrator.Install/capabilities.txt"
    [ "$(grep -c '^checks ' "${REPO_ROOT}/src/Credfeto.Orchestrator.Install/capabilities.txt")" -eq 6 ]
}
