#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/block-github-mcp-write-tools"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# Pipes a Claude Code PreToolUse hook payload for the given tool_name into the
# hook under test. status 0 = allowed, 2 = blocked (matches the hook's own
# contract).
run_hook() {
    local tool_name="$1"
    local payload
    payload=$(jq -n --arg name "$tool_name" '{tool_name: $name}')
    run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
}

@test "mcp__github__create_or_update_file is blocked" {
    run_hook "mcp__github__create_or_update_file"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bypassing local git hooks'* ]]
}

@test "mcp__github__delete_file is blocked" {
    run_hook "mcp__github__delete_file"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bypassing local git hooks'* ]]
}

@test "mcp__github__push_files is blocked" {
    run_hook "mcp__github__push_files"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bypassing local git hooks'* ]]
}

@test "mcp__github__merge_pull_request is blocked" {
    run_hook "mcp__github__merge_pull_request"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bypassing local git hooks'* ]]
}

@test "mcp__github__update_pull_request_branch is blocked" {
    run_hook "mcp__github__update_pull_request_branch"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bypassing local git hooks'* ]]
}

@test "a read-only mcp__github__ tool is allowed" {
    run_hook "mcp__github__get_pull_request"
    [ "${status}" -eq 0 ]
}

@test "mcp__github__search_code is allowed" {
    run_hook "mcp__github__search_code"
    [ "${status}" -eq 0 ]
}

@test "a non-mcp tool_name is allowed" {
    run_hook "Bash"
    [ "${status}" -eq 0 ]
}

@test "an empty tool_name is blocked (fail closed)" {
    run_hook ""
    [ "${status}" -eq 2 ]
}

@test "a payload with no tool_name field is blocked (fail closed)" {
    run bash -c 'printf "%s" "{}" | "$1"' _ "$HOOK"
    [ "${status}" -eq 2 ]
}

@test "the denial message states the command never ran (#1281)" {
    run_hook "mcp__github__delete_file"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'command did not run'* ]]
}

@test "a payload that does not parse as JSON is blocked (fail closed)" {
    run bash -c 'printf "not json" | "$1"' _ "$HOOK"
    [ "${status}" -eq 2 ]
}
