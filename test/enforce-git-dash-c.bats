#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-git-dash-c"

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

@test "bare git push is blocked" {
    run_hook "git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git -C <dir>'* ]]
}

@test "git alone with no subcommand is blocked" {
    run_hook "git"
    [ "${status}" -eq 2 ]
}

@test "git -C . push is allowed" {
    run_hook "git -C . push"
    [ "${status}" -eq 0 ]
}

@test "-c flags before -C are accepted as hardened" {
    run_hook "git -c core.pager=cat -C . log"
    [ "${status}" -eq 0 ]
}

@test "a single bare pipe before git is blocked" {
    run_hook "true | git push"
    [ "${status}" -eq 2 ]
}

@test "a double pipe (||) before git is blocked" {
    run_hook "false || git push"
    [ "${status}" -eq 2 ]
}

@test "a hardened invocation followed by a bare invocation via && is blocked" {
    run_hook "git -C . status && git push --force"
    [ "${status}" -eq 2 ]
}

@test "two hardened invocations chained with && are allowed" {
    run_hook "git -C . status && git -C . push --force"
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation followed by a bare invocation via ; is blocked" {
    run_hook "git -C . status; git push --force"
    [ "${status}" -eq 2 ]
}

@test "command substitution without -C is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'x=$(git rev-parse HEAD)'
    [ "${status}" -eq 2 ]
}

@test "command substitution with -C is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'x=$(git -C . rev-parse HEAD)'
    [ "${status}" -eq 0 ]
}

@test "backtick command substitution without -C is blocked" {
    # shellcheck disable=SC2016  # literal `...` — must reach the hook unexpanded
    run_hook 'x=`git push`'
    [ "${status}" -eq 2 ]
}

@test "backtick command substitution with -C is allowed" {
    # shellcheck disable=SC2016  # literal `...` — must reach the hook unexpanded
    run_hook 'x=`git -C . push`'
    [ "${status}" -eq 0 ]
}

@test "git -C . config --global is allowed by this hook (settings deny rule covers that layer)" {
    run_hook "git -C . config --global user.email test@example.com"
    [ "${status}" -eq 0 ]
}

@test "a non-git command is allowed" {
    run_hook "ls -la"
    [ "${status}" -eq 0 ]
}

@test "heredoc body text that merely looks like a bare git command is not blocked" {
    run_hook "$(printf 'cat <<EOF\ngit push\nEOF')"
    [ "${status}" -eq 0 ]
}
