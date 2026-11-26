#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_STATE (#252) for the lib/state writes: off, bash writes every file; on, each write asks
# ORCHESTRATOR_CMD state save-..., and writes the file in bash, with a warning, unless the tool wrote it (exit 0).
# test/oneshot-state-writes-parity.bats checks what both sides leave behind.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# A stand-in for the tool: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---) and its stdin to
# ${TEST_TMP}/cmd_stdin, writes "tool stderr" to stderr when it fails, and exits with ${TEST_TMP}/status (0 when
# absent). It writes no state file, so a file present afterwards was written by bash.
make_state_writes_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'cat >> "${TEST_TMP}/cmd_stdin"' \
        'status=0' \
        'if [ -f "${TEST_TMP}/status" ]; then status=$(cat "${TEST_TMP}/status"); fi' \
        '[ "${status}" = 0 ] || printf "tool stderr\n" >&2' \
        'exit "${status}"'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

make_write_state() {
    OWNER=owner
    REPO=repo
    REPO_FULL=owner/repo
    SESSION_BASE_DIR="${ORCHESTRATOR_STATE_DIR}/owner/repo"
}

# Runs every write once
run_every_state_write() {
    save_infra_failure_count PullRequest 7 2
    save_pr_invocation_counts 7 5 3
    save_issue_invocation_counts 9 6 0
    save_env_unblock_attempts 7 1
    save_rate_limit 1764000000
    save_precheck_result PullRequest_7 abc pass
    save_last_diagnostic PullRequest 7 $'two\nlines\n'
}

# Prints every file the writes leave, each as its name then its content in printf %q form
print_written_state() {
    local file
    for file in owner/repo/PullRequest_7.infra-failures owner/repo/PullRequest_7.invocations \
        owner/repo/Issue_9.invocations owner/repo/PullRequest_7.env-unblocks owner/rate-limit \
        owner/repo/PullRequest_7.precheck owner/repo/PullRequest_7.last-diagnostic; do
        if [ -f "${ORCHESTRATOR_STATE_DIR}/${file}" ]; then
            printf '%s %q\n' "${file}" "$(
                cat "${ORCHESTRATOR_STATE_DIR}/${file}"
                printf x
            )"
        fi
    done
}

BASH_WRITES="owner/repo/PullRequest_7.infra-failures $'2\nx'
owner/repo/PullRequest_7.invocations $'5 3\nx'
owner/repo/Issue_9.invocations $'6 0\nx'
owner/repo/PullRequest_7.env-unblocks $'1\nx'
owner/rate-limit $'1764000000\nx'
owner/repo/PullRequest_7.precheck $'abc\npass\nx'
owner/repo/PullRequest_7.last-diagnostic $'two\nlines\nx'"

@test "the lib/state writes never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_STATE is off (#252)" {
    make_state_writes_stub
    make_write_state
    ORCHESTRATOR_DOTNET_STATE=0
    run --separate-stderr run_every_state_write
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
    [ "${stderr}" = "" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
    [ "$(print_written_state)" = "${BASH_WRITES}" ]
}

@test "each lib/state write hands its options to ORCHESTRATOR_CMD state and leaves the file to it when switched on (#252)" {
    make_state_writes_stub
    make_write_state
    ORCHESTRATOR_DOTNET_STATE=1
    run --separate-stderr run_every_state_write
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
    [ "${stderr}" = "" ]
    local s="${SESSION_BASE_DIR}"
    [ "$(cat "${TEST_TMP}/cmd_args")" = "state
save-infra-failures
--session-dir
${s}
--type
PullRequest
--id
7
--count
2
---
state
save-invocations
--session-dir
${s}
--type
PullRequest
--id
7
--total
5
--idle
3
---
state
save-invocations
--session-dir
${s}
--type
Issue
--id
9
--total
6
--idle
0
---
state
save-env-unblock-attempts
--session-dir
${s}
--id
7
--total
1
---
state
save-rate-limit
--state-dir
${ORCHESTRATOR_STATE_DIR}
--owner
owner
--reset
1764000000
---
state
save-precheck-result
--session-dir
${s}
--key
PullRequest_7
--sha
abc
--status
pass
---
state
save-last-diagnostic
--session-dir
${s}
--type
PullRequest
--id
7
---" ]
    # Only save-last-diagnostic has a stdin: the text, and the newline the here-string adds
    [ "$(
        cat "${TEST_TMP}/cmd_stdin"
        printf x
    )" = $'two\nlines\n\nx' ]
    [ "$(print_written_state)" = "" ]
}

@test "each lib/state write warns and writes the file in bash when the tool does not write it (#252)" {
    local tool_status
    for tool_status in 1 2 3 125; do
        rm -rf "${ORCHESTRATOR_STATE_DIR}" "${TEST_TMP}/cmd_args"
        make_state_writes_stub
        make_write_state
        printf '%s' "${tool_status}" > "${TEST_TMP}/status"
        ORCHESTRATOR_DOTNET_STATE=1
        run --separate-stderr run_every_state_write
        [ "${status}" -eq 0 ]
        [ "${output}" = "" ]
        [ "$(grep -c "fake-orchestrator state save-[a-z-]* failed (exit ${tool_status}); writing it in bash instead" <<< "${stderr}")" -eq 7 ]
        [ "$(grep -c '^tool stderr$' <<< "${stderr}")" -eq 7 ]
        [ "$(print_written_state)" = "${BASH_WRITES}" ]
    done
}

@test "each lib/state write warns and writes the file in bash when ORCHESTRATOR_CMD is missing (#252)" {
    make_write_state
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    ORCHESTRATOR_DOTNET_STATE=1
    run --separate-stderr run_every_state_write
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
    [ "$(grep -c "no-such-tool state save-[a-z-]* failed (exit 127); writing it in bash instead" <<< "${stderr}")" -eq 7 ]
    [ "$(print_written_state)" = "${BASH_WRITES}" ]
}

@test "a counter write the tool does not make still dies in bash when bash cannot write it either (#252)" {
    make_state_writes_stub
    make_write_state
    printf '3' > "${TEST_TMP}/status"
    mkdir -p "${SESSION_BASE_DIR}/PullRequest_7.infra-failures"
    ORCHESTRATOR_DOTNET_STATE=1
    run --separate-stderr save_infra_failure_count PullRequest 7 2
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"writing it in bash instead"* ]]
    [[ "${stderr}" == *"Failed to write infra-failure guard file: ${SESSION_BASE_DIR}/PullRequest_7.infra-failures"* ]]
}
