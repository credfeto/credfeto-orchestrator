#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-background-for-long-running-commands"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# Pipes a Claude Code PreToolUse hook payload for the given Bash command into
# the hook under test. status 0 = allowed, 2 = blocked (matches the hook's
# own contract). run_in_background is omitted from the payload entirely
# unless explicitly passed, mirroring a Bash tool call that never set it.
run_hook() {
    local command="$1" run_in_background="${2:-}"
    local payload
    if [ -n "${run_in_background}" ]; then
        payload=$(jq -n --arg cmd "$command" --argjson bg "$run_in_background" '{tool_input: {command: $cmd, run_in_background: $bg}}')
    else
        payload=$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')
    fi
    run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
}

# --- git commit --------------------------------------------------------

@test "git commit without run_in_background is blocked" {
    run_hook "git -C . commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git commit must run with run_in_background: true'* ]]
}

@test "git commit with run_in_background false is blocked" {
    run_hook "git -C . commit -m test" false
    [ "${status}" -eq 2 ]
}

@test "git commit with run_in_background true is allowed" {
    run_hook "git -C . commit -m test" true
    [ "${status}" -eq 0 ]
}

@test "git commit with -c flags before -C is still blocked" {
    run_hook "git -c core.pager=cat -C . commit -m test"
    [ "${status}" -eq 2 ]
}

@test "a bare git commit prefixed with sudo is blocked" {
    run_hook "sudo git commit -m test"
    [ "${status}" -eq 2 ]
}

@test "a path-qualified git commit invocation is blocked" {
    run_hook "/usr/bin/git -C . commit -m test"
    [ "${status}" -eq 2 ]
}

@test "git commands unrelated to commit are allowed" {
    run_hook "git -C . status"
    [ "${status}" -eq 0 ]
    run_hook "git -C . push"
    [ "${status}" -eq 0 ]
}

# --- pre-commit ----------------------------------------------------------

@test "pre-commit without run_in_background is blocked" {
    run_hook "pre-commit --all-files"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'pre-commit must run with run_in_background: true'* ]]
}

@test "pre-commit with run_in_background true is allowed" {
    run_hook "pre-commit --all-files" true
    [ "${status}" -eq 0 ]
}

@test "a path-qualified pre-commit invocation is blocked" {
    run_hook "/home/user/hooks/pre-commit --all-files"
    [ "${status}" -eq 2 ]
}

# --- dotnet build / dotnet test ------------------------------------------

@test "dotnet build without run_in_background is blocked" {
    run_hook "dotnet build"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet build must run with run_in_background: true'* ]]
}

@test "dotnet build with run_in_background true is allowed" {
    run_hook "dotnet build" true
    [ "${status}" -eq 0 ]
}

@test "dotnet test without run_in_background is blocked" {
    run_hook "dotnet test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet test must run with run_in_background: true'* ]]
}

@test "dotnet test with run_in_background true is allowed" {
    run_hook "dotnet test" true
    [ "${status}" -eq 0 ]
}

@test "dotnet subcommands unrelated to build/test are allowed" {
    run_hook "dotnet restore"
    [ "${status}" -eq 0 ]
    run_hook "dotnet buildcheck -solution foo.slnx"
    [ "${status}" -eq 0 ]
}

# --- npm test / bun test -------------------------------------------------

@test "npm test without run_in_background is blocked" {
    run_hook "npm test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'npm test must run with run_in_background: true'* ]]
}

@test "npm test with run_in_background true is allowed" {
    run_hook "npm test" true
    [ "${status}" -eq 0 ]
}

@test "npm subcommands unrelated to test are allowed" {
    run_hook "npm install"
    [ "${status}" -eq 0 ]
    run_hook "npm run build"
    [ "${status}" -eq 0 ]
}

@test "bun test without run_in_background is blocked" {
    run_hook "bun test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bun test must run with run_in_background: true'* ]]
}

@test "bun test with run_in_background true is allowed" {
    run_hook "bun test" true
    [ "${status}" -eq 0 ]
}

@test "bun subcommands unrelated to test are allowed" {
    run_hook "bun install"
    [ "${status}" -eq 0 ]
}

# --- general behaviour ----------------------------------------------------

@test "an unrelated command is allowed regardless of run_in_background" {
    run_hook "ls -la"
    [ "${status}" -eq 0 ]
}

@test "a hardened git status followed by a bare git commit via && is blocked" {
    run_hook "git -C . status && git -C . commit -m test"
    [ "${status}" -eq 2 ]
}

@test "an unrelated command mentioning the word commit in an argument is allowed" {
    run_hook 'git -C . log --grep="fix commit message"'
    [ "${status}" -eq 0 ]
}

@test "a non-git command mentioning git commit in a string is allowed" {
    run_hook 'echo "please run git commit yourself"'
    [ "${status}" -eq 0 ]
}

@test "heredoc body text that merely looks like a dotnet test command is not blocked" {
    run_hook "$(printf 'cat <<EOF\ndotnet test\nEOF')"
    [ "${status}" -eq 0 ]
}

@test "eval wrapping a git commit command is opaque to this hook (eval is already blocked upstream by enforce-git-dash-c)" {
    run_hook 'eval "git commit -m test"'
    [ "${status}" -eq 0 ]
}

@test "an obfuscated git commit argument is opaque to this hook (reject-obfuscated-commands blocks it upstream)" {
    run_hook 'git "com""mit" -m test'
    [ "${status}" -eq 0 ]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook "if true; then git commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}

@test "an empty command is allowed" {
    run_hook ""
    [ "${status}" -eq 0 ]
}

@test "the denial message states the command never ran (#1281)" {
    run_hook "git -C . commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'command did not run'* ]]
}
