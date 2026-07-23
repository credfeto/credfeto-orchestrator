#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-context-budget"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# Creates a transcript file of roughly the given byte size under TEST_TMP and prints its path.
make_transcript() {
    local bytes="$1"
    local file="${TEST_TMP}/transcript-$$-${RANDOM}.jsonl"
    head -c "${bytes}" /dev/zero | tr '\0' 'x' > "${file}"
    printf '%s' "${file}"
}

# Pipes a Claude Code PreToolUse hook payload into the hook under test.
# status 0 = allowed, 2 = blocked (matches the hook's own contract).
run_hook() {
    local tool_name="$1" command="$2" transcript_path="$3"
    local payload
    payload=$(jq -n --arg tool "${tool_name}" --arg cmd "${command}" --arg t "${transcript_path}" \
        '{tool_name: $tool, tool_input: {command: $cmd}, transcript_path: $t}')
    run bash -c 'printf "%s" "$1" | "$2"' _ "${payload}" "${HOOK}"
}

@test "small transcript under the default budget: an arbitrary Bash command is allowed" {
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "ls -la" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "no transcript_path in the payload: allowed (fails open, not a security boundary)" {
    run_hook "Bash" "ls -la" ""
    [ "${status}" -eq 0 ]
}

@test "transcript_path points at a file that does not exist: allowed (fails open)" {
    run_hook "Bash" "ls -la" "${TEST_TMP}/does-not-exist.jsonl"
    [ "${status}" -eq 0 ]
}

@test "over budget: git commit is allowed" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "git commit -m 'checkpoint'" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "over budget: git add is allowed" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "git add -A" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "over budget: git push is allowed" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "git push origin HEAD" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "over budget: gh pr comment is allowed" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "gh pr comment 1236 --body 'checkpoint'" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "over budget: gh issue comment is allowed" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "gh issue comment 1070 --body 'checkpoint'" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "over budget: gh pr edit (e.g. to add the Blocked label) is allowed" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "gh pr edit 1236 --add-label Blocked" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "over budget: gh pr view is allowed" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "gh pr view 1236" "${transcript}"
    [ "${status}" -eq 0 ]
}

@test "over budget: an unrelated Bash command is blocked" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "dotnet build" "${transcript}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'Context budget reached'* ]]
}

@test "over budget: a git subcommand not on the checkpoint allow-list is blocked" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "git checkout -b new-branch" "${transcript}"
    [ "${status}" -eq 2 ]
}

@test "over budget: a checkpoint command chained with a non-checkpoint one is blocked as a whole" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "git commit -m checkpoint && rm -rf /tmp/whatever" "${transcript}"
    [ "${status}" -eq 2 ]
}

@test "over budget: the Edit tool is blocked" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Edit" "" "${transcript}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'Context budget reached'* ]]
}

@test "over budget: the Write tool is blocked" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Write" "" "${transcript}"
    [ "${status}" -eq 2 ]
}

@test "over budget: a command that does not parse as shell is blocked (fail closed)" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS=1
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "if true; then git commit" "${transcript}"
    [ "${status}" -eq 2 ]
}

@test "an invalid (non-numeric) budget env var falls back to the default and stays under it" {
    export CLAUDE_CONTEXT_BUDGET_TOKENS="not-a-number"
    local transcript
    transcript=$(make_transcript 100)
    run_hook "Bash" "ls -la" "${transcript}"
    [ "${status}" -eq 0 ]
}
