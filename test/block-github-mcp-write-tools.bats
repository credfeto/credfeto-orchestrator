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

@test "each write-capable mcp__github__ tool is blocked, naming the command and stating it never ran (#1281)" {
    local tool
    for tool in mcp__github__create_or_update_file mcp__github__delete_file mcp__github__push_files mcp__github__merge_pull_request mcp__github__update_pull_request_branch; do
        run_hook "${tool}"
        [ "${status}" -eq 2 ] || { echo "did not block ${tool}: ${output}" >&2; return 1; }
        [[ "${output}" == *'bypassing local git hooks'* ]] || { echo "missing bypass message for ${tool}: ${output}" >&2; return 1; }
        [[ "${output}" == *'command did not run'* ]] || { echo "missing 'command did not run' for ${tool}: ${output}" >&2; return 1; }
    done
}

@test "a read-only mcp__github__ tool is allowed" {
    local tool
    for tool in mcp__github__get_pull_request mcp__github__search_code; do
        run_hook "${tool}"
        [ "${status}" -eq 0 ] || { echo "did not allow ${tool}: ${output}" >&2; return 1; }
    done
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

@test "a payload that does not parse as JSON is blocked (fail closed)" {
    run bash -c 'printf "not json" | "$1"' _ "$HOOK"
    [ "${status}" -eq 2 ]
}
