#!/usr/bin/env bats

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-git-identity"

setup() {
    setup_isolated_env
    # setup_isolated_env gives an empty HOME and ignores /etc/gitconfig, so the
    # global identity is unset and any gated command is blocked.
    export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
    : > "${GIT_CONFIG_GLOBAL}"
}

teardown() {
    cleanup_stubs
}

run_hook() {
    local command="$1"
    local payload
    payload=$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')
    run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
}

@test "git commit with no identity configured is blocked" {
    run_hook "git commit -m x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'user.email is not set'* ]]
}

@test "a backslash-escaped letter inside the commit subcommand is still identity-checked" {
    run_hook 'git com\mit -m x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'user.email is not set'* ]]
}

@test "a backslash-escaped letter inside the git command name is still identity-checked" {
    run_hook 'g\it commit -m x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'user.email is not set'* ]]
}

@test "git status is not identity-checked" {
    run_hook "git status"
    [ "${status}" -eq 0 ]
}

@test "a non-git command is not identity-checked" {
    run_hook "ls -la"
    [ "${status}" -eq 0 ]
}
