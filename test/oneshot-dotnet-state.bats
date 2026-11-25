#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_STATE (#252): off by default; when on, the read-only lib/state queries ask ORCHESTRATOR_CMD
# state, take its answer when it gives one (exit 0 or 1, or 4 from rate-limit) and run their bash version, with a
# warning, when it does not. test/oneshot-state-parity.bats checks what both sides print and return.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# A stand-in for the tool: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---), writes "tool stderr"
# to stderr only when it fails, prints ${TEST_TMP}/answer and exits with ${TEST_TMP}/status (0 when absent)
make_state_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'if [ -f "${TEST_TMP}/answer" ]; then cat "${TEST_TMP}/answer"; fi' \
        'status=0' \
        'if [ -f "${TEST_TMP}/status" ]; then status=$(cat "${TEST_TMP}/status"); fi' \
        'case "${status}" in 0 | 1 | 4) ;; *) printf "tool stderr\n" >&2 ;; esac' \
        'exit "${status}"'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

_tool_answers() {
    printf '%s' "$1" > "${TEST_TMP}/answer"
    printf '%s' "$2" > "${TEST_TMP}/status"
}

# State files every bash query answers from: SESSION_BASE_DIR and the owner's directory under ORCHESTRATOR_STATE_DIR
make_bash_state() {
    OWNER=owner
    REPO=repo
    REPO_FULL=owner/repo
    SESSION_BASE_DIR="${ORCHESTRATOR_STATE_DIR}/owner/repo"
    mkdir -p "${SESSION_BASE_DIR}"
    printf '2\n' > "${SESSION_BASE_DIR}/PullRequest_7.infra-failures"
    printf '5 3\n' > "${SESSION_BASE_DIR}/PullRequest_7.invocations"
    printf '6\n' > "${SESSION_BASE_DIR}/Issue_9.invocations"
    printf '1\n' > "${SESSION_BASE_DIR}/PullRequest_7.env-unblocks"
    : > "${SESSION_BASE_DIR}/Issue_9.plan-block"
    : > "${SESSION_BASE_DIR}/PullRequest_7.background-stall"
    printf 'bash diagnostic' > "${SESSION_BASE_DIR}/PullRequest_7.last-diagnostic"
    printf 'abc\npass\n' > "${SESSION_BASE_DIR}/PullRequest_7.precheck"
    printf '10\n20\n30\n40\n50\n' > "${ORCHESTRATOR_STATE_DIR}/owner/pull-durations"
    printf '99999999999\n' > "${ORCHESTRATOR_STATE_DIR}/owner/rate-limit"
    printf 'ts\towner/repo\tIssue\t9\t1\t0\t0\tcat\n' > "${ORCHESTRATOR_STATE_DIR}/owner/session-denials.2026-11-24"
}

# Runs every query once, printing one line each: what it printed or set, then its status
run_every_state_query() {
    load_infra_failure_count PullRequest 7
    printf 'infra %s %s\n' "${INFRA_FAILURE_COUNT}" "$?"
    load_pr_invocation_counts 7
    printf 'pr %s/%s %s\n' "${PR_INVOCATION_TOTAL}" "${PR_INVOCATION_IDLE}" "$?"
    load_issue_invocation_counts 9
    printf 'issue %s/%s %s\n' "${ISSUE_INVOCATION_TOTAL}" "${ISSUE_INVOCATION_IDLE}" "$?"
    load_env_unblock_attempts 7
    printf 'env %s %s\n' "${ENV_UNBLOCK_ATTEMPTS}" "$?"
    issue_plan_block_marked 9
    printf 'plan-block %s\n' "$?"
    issue_blocked_replan_marked 9
    printf 'blocked-replan %s\n' "$?"
    background_stall_marked PullRequest 7
    printf 'background-stall %s\n' "$?"
    printf 'diagnostic [%s] %s\n' "$(load_last_diagnostic PullRequest 7)" "$?"
    printf 'precheck [%s] %s\n' "$(load_precheck_result PullRequest_7 abc)" "$?"
    printf 'baseline [%s] %s\n' "$(pull_duration_baseline)" "$?"
    is_owner_rate_limited
    printf 'rate-limited %s\n' "$?"
    printf 'summary %s %s\n' "$(summarise_session_denials_day "${ORCHESTRATOR_STATE_DIR}/owner/session-denials.2026-11-24")" "$?"
}

BASH_ANSWERS='infra 2 0
pr 5/3 0
issue 6/0 0
env 1 0
plan-block 0
blocked-replan 1
background-stall 0
diagnostic [bash diagnostic] 0
precheck [pass] 0
baseline [30] 0
rate-limited 0
summary {"sessions":1,"denials":1,"stalled":0,"quits":0,"repos":[{"repo":"owner/repo","sessions":1,"denials":1,"stalled":0}],"top_commands":[{"name":"cat","count":1}]} 0'

@test "ORCHESTRATOR_DOTNET_STATE defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_STATE bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_STATE}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "the lib/state queries never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_STATE is off (#252)" {
    make_state_cmd_stub
    make_bash_state
    ORCHESTRATOR_DOTNET_STATE=0
    run --separate-stderr run_every_state_query
    [ "${status}" -eq 0 ]
    [ "${output}" = "${BASH_ANSWERS}" ]
    [ "${stderr}" = "" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "each lib/state query hands its query and options to ORCHESTRATOR_CMD state when switched on (#252)" {
    make_state_cmd_stub
    make_bash_state
    _tool_answers "" 1
    ORCHESTRATOR_DOTNET_STATE=1
    PULL_DURATION_MIN_SAMPLES=4
    run run_every_state_query
    local s="${SESSION_BASE_DIR}" o="${ORCHESTRATOR_STATE_DIR}"
    [ "$(cat "${TEST_TMP}/cmd_args")" = "state
infra-failures
--session-dir
${s}
--type
PullRequest
--id
7
---
state
invocations
--session-dir
${s}
--type
PullRequest
--id
7
---
state
invocations
--session-dir
${s}
--type
Issue
--id
9
---
state
env-unblock-attempts
--session-dir
${s}
--id
7
---
state
marker
--session-dir
${s}
--type
Issue
--id
9
--kind
plan-block
---
state
marker
--session-dir
${s}
--type
Issue
--id
9
--kind
blocked-replan
---
state
marker
--session-dir
${s}
--type
PullRequest
--id
7
--kind
background-stall
---
state
last-diagnostic
--session-dir
${s}
--type
PullRequest
--id
7
---
state
precheck-result
--session-dir
${s}
--key
PullRequest_7
--sha
abc
---
state
pull-duration-baseline
--state-dir
${o}
--owner
owner
--min-samples
4
---
state
rate-limit
--state-dir
${o}
--owner
owner
---
state
session-denials-summary
--file
${o}/owner/session-denials.2026-11-24
---" ]
}

@test "the queries take the tool's answer: its text byte for byte, trailing newlines kept, and its status (#252)" {
    make_state_cmd_stub
    make_bash_state
    ORCHESTRATOR_DOTNET_STATE=1
    local text
    _tool_answers "12" 0
    load_infra_failure_count PullRequest 7
    [ "${INFRA_FAILURE_COUNT}" = 12 ]
    load_env_unblock_attempts 7
    [ "${ENV_UNBLOCK_ATTEMPTS}" = 12 ]
    _tool_answers "8 4" 0
    load_pr_invocation_counts 7
    [ "${PR_INVOCATION_TOTAL}" = 8 ]
    [ "${PR_INVOCATION_IDLE}" = 4 ]
    load_issue_invocation_counts 9
    [ "${ISSUE_INVOCATION_TOTAL}" = 8 ]
    [ "${ISSUE_INVOCATION_IDLE}" = 4 ]
    _tool_answers $'tool diagnostic\n\n' 0
    text=$(
        load_last_diagnostic PullRequest 7
        printf x
    )
    [ "${text}" = $'tool diagnostic\n\nx' ]
    _tool_answers $'15\n' 0
    text=$(
        pull_duration_baseline
        printf x
    )
    [ "${text}" = $'15\nx' ]
    _tool_answers "" 1
    run --separate-stderr pull_duration_baseline
    [ "${status}" -eq 1 ]
    [ "${output}" = "" ]
    run --separate-stderr issue_blocked_replan_marked 9
    [ "${status}" -eq 1 ]
    run --separate-stderr load_precheck_result PullRequest_7 abc
    [ "${status}" -eq 1 ]
    [ "${output}" = "" ]
    _tool_answers "" 0
    issue_blocked_replan_marked 3
    _tool_answers "fail" 0
    [ "$(load_precheck_result main abc)" = fail ]
    _tool_answers "null" 0
    [ "$(summarise_session_denials_day "${ORCHESTRATOR_STATE_DIR}/owner/session-denials.2026-11-24")" = null ]
}

@test "is_owner_rate_limited keeps the rate-limit file on the tool's 0 and 1 and removes it on its 4 (#252)" {
    make_state_cmd_stub
    make_bash_state
    ORCHESTRATOR_DOTNET_STATE=1
    _tool_answers "" 0
    run --separate-stderr is_owner_rate_limited
    [ "${status}" -eq 0 ]
    [ -f "${ORCHESTRATOR_STATE_DIR}/owner/rate-limit" ]
    _tool_answers "" 1
    run --separate-stderr is_owner_rate_limited
    [ "${status}" -eq 1 ]
    [ -f "${ORCHESTRATOR_STATE_DIR}/owner/rate-limit" ]
    _tool_answers "" 4
    run --separate-stderr is_owner_rate_limited
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "" ]
    [ ! -e "${ORCHESTRATOR_STATE_DIR}/owner/rate-limit" ]
}

@test "a query answers in bash, with a warning, when ORCHESTRATOR_CMD refuses, fails or is missing (#252)" {
    make_state_cmd_stub
    make_bash_state
    ORCHESTRATOR_DOTNET_STATE=1
    local exit_code
    for exit_code in 2 3 5 125 130 143; do
        _tool_answers "wrong" "${exit_code}"
        run --separate-stderr run_every_state_query
        [ "${status}" -eq 0 ]
        [ "${output}" = "${BASH_ANSWERS}" ]
        [[ "${stderr}" == *"tool stderr"*"fake-orchestrator state infra-failures failed (exit ${exit_code}); answering in bash instead"* ]]
        [[ "${stderr}" == *"fake-orchestrator state session-denials-summary failed (exit ${exit_code}); answering in bash instead"* ]]
        [ "$(grep -c 'answering in bash instead' <<< "${stderr}")" -eq 12 ]
        [ -f "${ORCHESTRATOR_STATE_DIR}/owner/rate-limit" ]
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr run_every_state_query
    [ "${output}" = "${BASH_ANSWERS}" ]
    [[ "${stderr}" == *"no-such-tool state rate-limit failed (exit 127); answering in bash instead"* ]]
}

@test "pull_duration_exceeds_baseline and mark_capped_block_for_forgiveness use the tool's answers when switched on (#252)" {
    make_state_cmd_stub
    make_bash_state
    ORCHESTRATOR_DOTNET_STATE=1
    PULL_DURATION_THRESHOLD_MULTIPLIER=3
    _tool_answers $'10\n' 0
    [ "$(pull_duration_exceeds_baseline 31)" = 10 ]
    run pull_duration_exceeds_baseline 30
    [ "${status}" -eq 1 ]
    MAX_PR_TOTAL_INVOCATIONS=50
    MAX_PR_IDLE_INVOCATIONS=5
    _tool_answers "1 5" 0
    mark_capped_block_for_forgiveness PullRequest 7 owner/repo
    [ -f "${SESSION_BASE_DIR}/PullRequest_7.runaway-blocked" ]
    _tool_answers "1 4" 0
    mark_capped_block_for_forgiveness PullRequest 8 owner/repo
    [ ! -e "${SESSION_BASE_DIR}/PullRequest_8.runaway-blocked" ]
}
