#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/block-git-worktree"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# Pipes a Claude Code PreToolUse hook payload for the given Bash command into
# the hook under test. status 0 = allowed, 2 = blocked (matches the hook's
# own contract).
run_hook() {
    local command="$1"
    local payload
    payload=$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')
    run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
}

@test "git worktree add is blocked" {
    run_hook "git worktree add ../foo -b feature/x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git worktree add is prohibited'* ]]
}

@test "git -C . worktree add is blocked" {
    run_hook "git -C . worktree add ../foo -b feature/x"
    [ "${status}" -eq 2 ]
}

@test "-c flags before -C are still checked for worktree add" {
    run_hook "git -c core.pager=cat -C . worktree add ../foo"
    [ "${status}" -eq 2 ]
}

@test "git worktree remove is allowed" {
    run_hook "git worktree remove ../foo"
    [ "${status}" -eq 0 ]
}

@test "git worktree list is allowed" {
    run_hook "git worktree list"
    [ "${status}" -eq 0 ]
}

@test "git worktree prune is allowed" {
    run_hook "git worktree prune"
    [ "${status}" -eq 0 ]
}

@test "git worktree lock is allowed" {
    run_hook "git worktree lock ../foo"
    [ "${status}" -eq 0 ]
}

@test "git worktree unlock is allowed" {
    run_hook "git worktree unlock ../foo"
    [ "${status}" -eq 0 ]
}

@test "git worktree move is allowed" {
    run_hook "git worktree move ../foo ../bar"
    [ "${status}" -eq 0 ]
}

@test "git worktree repair is allowed" {
    run_hook "git worktree repair"
    [ "${status}" -eq 0 ]
}

@test "git worktree with no subcommand is allowed" {
    run_hook "git worktree"
    [ "${status}" -eq 0 ]
}

@test "a normal git -C . push is allowed" {
    run_hook "git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a normal bare git push (not this hook's concern) is allowed" {
    run_hook "git push"
    [ "${status}" -eq 0 ]
}

@test "git alone with no subcommand is allowed" {
    run_hook "git"
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation followed by a bare worktree add via && is blocked" {
    run_hook "git -C . status && git worktree add ../foo"
    [ "${status}" -eq 2 ]
}

@test "a hardened invocation followed by a bare worktree remove via && is allowed" {
    run_hook "git -C . status && git worktree remove ../foo"
    [ "${status}" -eq 0 ]
}

@test "a bare worktree add prefixed with sudo is blocked" {
    run_hook "sudo git worktree add ../foo"
    [ "${status}" -eq 2 ]
}

@test "a path-qualified git worktree add invocation is blocked" {
    run_hook "/usr/bin/git worktree add ../foo"
    [ "${status}" -eq 2 ]
}

@test "a command substitution invoking worktree add is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'x=$(git worktree add ../foo)'
    [ "${status}" -eq 2 ]
}

@test "an unrelated command mentioning the word worktree in an argument is allowed" {
    run_hook 'git -C . log --grep="worktree cleanup"'
    [ "${status}" -eq 0 ]
}

@test "a non-git command mentioning worktree add is allowed" {
    run_hook 'echo "please avoid git worktree add"'
    [ "${status}" -eq 0 ]
}

@test "eval wrapping a worktree add command is opaque to this hook (eval is already blocked upstream by enforce-git-dash-c)" {
    run_hook 'eval "git worktree add ../foo"'
    [ "${status}" -eq 0 ]
}

@test "a non-git command is allowed" {
    run_hook "ls -la"
    [ "${status}" -eq 0 ]
}

@test "heredoc body text that merely looks like a worktree add command is not blocked" {
    run_hook "$(printf 'cat <<EOF\ngit worktree add ../foo\nEOF')"
    [ "${status}" -eq 0 ]
}

@test "an obfuscated worktree add argument is opaque to this hook (reject-obfuscated-commands blocks it upstream)" {
    run_hook 'git "work""tree" add ../foo'
    [ "${status}" -eq 0 ]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook "if true; then git worktree add"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}
