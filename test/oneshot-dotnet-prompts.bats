#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_PROMPTS (#252): off by default; when on, the lib/prompts builders and the MAX_PROMPT_CHARS
# count hand their inputs to ORCHESTRATOR_CMD, and fall back to bash when the tool fails.
# test/oneshot-prompts-parity.bats checks what both sides print.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# A stand-in for the tool: records its arguments and its stdin, then prints a fixed text with a blank line at the
# end (check-length: the length in ${TEST_TMP}/length with the exit status in ${TEST_TMP}/length_status), or fails
# when ${TEST_TMP}/fail exists.
make_prompt_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        'printf "%s\n" "$@" > "${TEST_TMP}/cmd_args"' \
        'cat > "${TEST_TMP}/cmd_stdin"' \
        '[ -f "${TEST_TMP}/fail" ] && exit 1' \
        'if [ "$2" = check-length ]; then cat "${TEST_TMP}/length"; exit "$(cat "${TEST_TMP}/length_status")"; fi' \
        'printf "from the tool\n\n"'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

# The records the stub was sent, one a line (each NUL shown as a newline)
_sent_records() {
    tr '\0' '\n' < "${TEST_TMP}/cmd_stdin"
}

_setup_prompt_globals() {
    REPO_FULL=org/repo
    REPO_WORK_DIR=/work/default
    _WF_PROJECT_ID=PVT_x
    _WF_STATUS_ORDER=("Not Started" "Done")
}

@test "ORCHESTRATOR_DOTNET_PROMPTS defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_PROMPTS bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_PROMPTS}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "the prompt builders and the length guard never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_PROMPTS is off (#252)" {
    make_prompt_cmd_stub
    _setup_prompt_globals
    ORCHESTRATOR_DOTNET_PROMPTS=0
    build_issue_claude_md 1 /ai > /dev/null
    build_pr_claude_md 2 /ai > /dev/null
    build_issue_prompt 1 /ai > /dev/null
    build_pr_prompt 2 /ai > /dev/null
    build_precheck_section pr abc pass "" "" "" > /dev/null
    run prompt_exceeds_max_chars "short"
    [ "${status}" -eq 1 ]
    [ "${output}" = "5" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "build_issue_claude_md hands its arguments after their defaults, the board settings and the statuses to ORCHESTRATOR_CMD (#252)" {
    make_prompt_cmd_stub
    _setup_prompt_globals
    ORCHESTRATOR_DOTNET_PROMPTS=1
    local text
    text=$(
        build_issue_claude_md 7 /ai "" "" '["me"]' dirty stale "" "PRE"$'\n'
        printf x
    )
    [ "${text}" = $'from the tool\n\nx' ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = $'prompt\nissue-claude-md' ]
    [ "$(_sent_records)" = 'repo-full=org/repo
board=true
wf-status=Not Started
wf-status=Done
item=7
ai-instructions=/ai
repo-path=/work/default
plan-approved=false
trusted-logins=["me"]
dirty-branch=dirty
stale-branch=stale
background-stall=false
precheck-section=PRE' ]
}

@test "build_pr_claude_md hands the review settings and its arguments to ORCHESTRATOR_CMD, the dependency branch defaulting to the dependency flag (#252)" {
    make_prompt_cmd_stub
    _setup_prompt_globals
    _WF_PROJECT_ID=""
    ORCHESTRATOR_DOTNET_PROMPTS=1
    run build_pr_claude_md 8 /ai BEHIND feat/x "" "" true
    [ "${status}" -eq 0 ]
    [ "${output}" = "from the tool" ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = $'prompt\npr-claude-md' ]
    local records
    records=$(_sent_records)
    [[ "${records}" == *$'board=false\n'* ]]
    [[ "${records}" == *$'round-marker-simplify='"${ROUND_MARKER_SIMPLIFY}"$'\n'* ]]
    [[ "${records}" == *$'max-code-review-iterations='"${MAX_CODE_REVIEW_ITERATIONS}"$'\n'* ]]
    [[ "${records}" == *$'min-review-convergence-rounds='"${MIN_REVIEW_CONVERGENCE_ROUNDS}"$'\n'* ]]
    [[ "${records}" == *$'merge-state=BEHIND\nbranch=feat/x\nrepo-path=/work/default\n'* ]]
    [[ "${records}" == *$'dependency-pr=true\n'* ]]
    [[ "${records}" == *$'\ndependency-branch=true' ]]
    [ "$(grep -c '' <<< "${records}")" -eq 29 ]
}

@test "the launch prompts and the pre-check section hand their own records to ORCHESTRATOR_CMD (#252)" {
    make_prompt_cmd_stub
    _setup_prompt_globals
    ORCHESTRATOR_DOTNET_PROMPTS=1
    build_issue_prompt 3 /ai > /dev/null
    [ "$(cat "${TEST_TMP}/cmd_args")" = $'prompt\nissue-launch' ]
    [ "$(_sent_records)" = $'repo-full=org/repo\nitem=3\nrepo-path=/work/default' ]
    build_pr_prompt 4 /ai CLEAN feat/y /w > /dev/null
    [ "$(cat "${TEST_TMP}/cmd_args")" = $'prompt\npr-launch' ]
    [ "$(_sent_records)" = $'repo-full=org/repo\nitem=4\nrepo-path=/w' ]
    build_precheck_section main sha1 fail "  hook" "" /log > /dev/null
    [ "$(cat "${TEST_TMP}/cmd_args")" = $'prompt\nprecheck-section' ]
    [ "$(_sent_records)" = "precheck-summary-lines=${PRECHECK_SUMMARY_LINES}
precheck-timeout-minutes=${PRECHECK_TIMEOUT_MINUTES}
kind=main
sha=sha1
status=fail
summary=  hook
error=
container-log=/log" ]
}

@test "a value holding newlines and other bytes reaches ORCHESTRATOR_CMD unchanged, each record ended by a NUL byte (#252)" {
    make_prompt_cmd_stub
    _setup_prompt_globals
    ORCHESTRATOR_DOTNET_PROMPTS=1
    local path=$'/w/a b\n\n$x `y` é\n'
    build_issue_prompt 5 /ai "${path}" > /dev/null
    printf 'repo-full=org/repo\0item=5\0repo-path=%s\0' "${path}" > "${TEST_TMP}/expected_stdin"
    cmp "${TEST_TMP}/expected_stdin" "${TEST_TMP}/cmd_stdin"
}

@test "a builder prints exactly what bash prints, with a warning, when ORCHESTRATOR_CMD fails (#252)" {
    make_prompt_cmd_stub
    _setup_prompt_globals
    touch "${TEST_TMP}/fail"
    local expected actual
    ORCHESTRATOR_DOTNET_PROMPTS=0
    expected=$(
        build_pr_claude_md 9 /ai DIRTY feat/z /w feat/z
        printf x
    )
    ORCHESTRATOR_DOTNET_PROMPTS=1
    actual=$(
        build_pr_claude_md 9 /ai DIRTY feat/z /w feat/z 2> "${TEST_TMP}/stderr"
        printf x
    )
    [ "${actual}" = "${expected}" ]
    grep -q "fake-orchestrator prompt pr-claude-md failed; building it in bash instead" "${TEST_TMP}/stderr"

    ORCHESTRATOR_CMD=no-such-orchestrator-command
    actual=$(
        build_issue_prompt 9 /ai /w 2> /dev/null
        printf x
    )
    [ "${actual}" = $'Work on issue #9 in org/repo.\nThe repository is checked out at /w.\nx' ]
}

@test "prompt_exceeds_max_chars takes the tool's count and verdict when switched on, and counts in bash when the tool fails (#252)" {
    make_prompt_cmd_stub
    ORCHESTRATOR_DOTNET_PROMPTS=1
    printf '42\n' > "${TEST_TMP}/length"
    printf '3' > "${TEST_TMP}/length_status"
    run prompt_exceeds_max_chars "abc"
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
    [ "$(cat "${TEST_TMP}/cmd_args")" = "$(printf 'prompt\ncheck-length\n--max\n%s' "${MAX_PROMPT_CHARS}")" ]
    [ "$(cat "${TEST_TMP}/cmd_stdin")" = "abc" ]

    printf '0' > "${TEST_TMP}/length_status"
    run prompt_exceeds_max_chars "abc"
    [ "${status}" -eq 1 ]
    [ "${output}" = "42" ]

    touch "${TEST_TMP}/fail"
    MAX_PROMPT_CHARS=2
    run --separate-stderr prompt_exceeds_max_chars "abc"
    [ "${status}" -eq 0 ]
    [ "${output}" = "3" ]
    [[ "${stderr}" == *"counting the prompt in bash instead"* ]]
}

@test "invoke_claude stops before podman when the tool counts the prompt over MAX_PROMPT_CHARS (#252)" {
    make_prompt_cmd_stub
    make_stub podman 'printf "%s\n" "$@" >> "${TEST_TMP}/podman_args"'
    ORCHESTRATOR_DOTNET_PROMPTS=1
    DISCORD_WEBHOOK_URL=""
    printf '100001\n' > "${TEST_TMP}/length"
    printf '3' > "${TEST_TMP}/length_status"
    run invoke_claude "short" "Issue" "1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Prompt is too long: 100001 characters exceeds limit of ${MAX_PROMPT_CHARS}"* ]]
    [ ! -f "${TEST_TMP}/podman_args" ]
}
