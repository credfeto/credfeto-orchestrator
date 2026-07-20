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

@test "a bare git backgrounded with a single & is blocked" {
    run_hook "true & git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git inside a brace group is blocked" {
    run_hook "{ git push; }"
    [ "${status}" -eq 2 ]
}

@test "a command substitution inside double quotes is still checked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'echo "$(git push)"'
    [ "${status}" -eq 2 ]
}

@test "a hardened command substitution inside double quotes is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'echo "$(git -C . push)"'
    [ "${status}" -eq 0 ]
}

@test "a bare git after a quoted close-paren inside a top-level command substitution is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook '$(echo ")" && git push)'
    [ "${status}" -eq 2 ]
}

@test "a bare git after a quoted close-paren inside a top-level backtick substitution is blocked" {
    # shellcheck disable=SC2016  # literal backticks — must reach the hook unexpanded
    run_hook 'echo `echo ")" && git push`'
    [ "${status}" -eq 2 ]
}

@test "a hardened git after a quoted close-paren inside a top-level command substitution is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook '$(echo ")" && git -C . push)'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with parens inside a quoted grep pattern is not falsely blocked" {
    run_hook 'git -C . log --grep="(WIP) git stuff"'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with a semicolon inside a quoted grep pattern is not falsely blocked" {
    run_hook 'git -C . log --grep="fix a; git push later"'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with an ampersand inside a quoted grep pattern is not falsely blocked" {
    run_hook 'git -C . log --grep="wip & git gc"'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with braces inside a quoted commit message is not falsely blocked" {
    run_hook 'git -C . commit -m "wip {git}"'
    [ "${status}" -eq 0 ]
}

@test "a single-quoted commit message containing an ampersand is not falsely blocked" {
    run_hook "git -C . commit -m 'stuff & things'"
    [ "${status}" -eq 0 ]
}

@test "a non-git command containing parens in a quoted argument is not falsely blocked" {
    run_hook 'echo "(git is great)"'
    [ "${status}" -eq 0 ]
}

@test "git -C . config --global is allowed by this hook (settings deny rule covers that layer)" {
    run_hook "git -C . config --global user.email test@example.com"
    [ "${status}" -eq 0 ]
}

@test "bare git clone is exempted from -C" {
    run_hook "git clone https://example.com/repo.git /tmp/repo"
    [ "${status}" -eq 0 ]
}

@test "bare git clone with flags before the url is exempted from -C" {
    run_hook "git clone --depth 1 https://example.com/repo.git"
    [ "${status}" -eq 0 ]
}

@test "bare git config --global --get is exempted from -C" {
    run_hook "git config --global --get user.email"
    [ "${status}" -eq 0 ]
}

@test "bare git config --get --global (flags reversed) is exempted from -C" {
    run_hook "git config --get --global user.email"
    [ "${status}" -eq 0 ]
}

@test "bare git config --system --get-all is exempted from -C" {
    run_hook "git config --system --get-all safe.directory"
    [ "${status}" -eq 0 ]
}

@test "bare git config --global --get-regexp is exempted from -C" {
    run_hook 'git config --global --get-regexp "^user\."'
    [ "${status}" -eq 0 ]
}

@test "bare git config --global --list is exempted from -C" {
    run_hook "git config --global --list"
    [ "${status}" -eq 0 ]
}

@test "bare git config --global with no read/write flag is still blocked" {
    run_hook "git config --global user.email"
    [ "${status}" -eq 2 ]
}

@test "bare git config --global write (set) is still blocked" {
    run_hook "git config --global user.email test@example.com"
    [ "${status}" -eq 2 ]
}

@test "bare git config --global --add is still blocked" {
    run_hook "git config --global --add safe.directory /x"
    [ "${status}" -eq 2 ]
}

@test "bare git config --global --unset is still blocked" {
    run_hook "git config --global --unset user.email"
    [ "${status}" -eq 2 ]
}

@test "bare git config --get without --global/--system is still blocked" {
    run_hook "git config --get user.email"
    [ "${status}" -eq 2 ]
}

@test "bare git config --list without --global/--system is still blocked" {
    run_hook "git config --list"
    [ "${status}" -eq 2 ]
}

@test "bare git config plain (no scope, no action) is still blocked" {
    run_hook "git config user.email"
    [ "${status}" -eq 2 ]
}

@test "a non-git command is allowed" {
    run_hook "ls -la"
    [ "${status}" -eq 0 ]
}

@test "heredoc body text that merely looks like a bare git command is not blocked" {
    run_hook "$(printf 'cat <<EOF\ngit push\nEOF')"
    [ "${status}" -eq 0 ]
}

@test "a bare git negated with ! is blocked" {
    run_hook "! git push"
    [ "${status}" -eq 2 ]
}

@test "a hardened git negated with ! is allowed" {
    run_hook "! git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a bare git prefixed with sudo is blocked" {
    run_hook "sudo git push"
    [ "${status}" -eq 2 ]
}

@test "a hardened git prefixed with sudo is allowed" {
    run_hook "sudo git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a bare git prefixed with env is blocked" {
    run_hook "env git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git prefixed with exec is blocked" {
    run_hook "exec git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git prefixed with command is blocked" {
    run_hook "command git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git prefixed with time is blocked" {
    run_hook "time git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git inside a for-loop do body is blocked" {
    run_hook "for i in 1; do git push; done"
    [ "${status}" -eq 2 ]
}

@test "a hardened git inside a for-loop do body is allowed" {
    run_hook "for i in 1; do git -C . push; done"
    [ "${status}" -eq 0 ]
}

@test "a bare git inside an if/then body is blocked" {
    run_hook "if true; then git push; fi"
    [ "${status}" -eq 2 ]
}

@test "a bare git inside an if/else body is blocked" {
    run_hook "if false; then true; else git push; fi"
    [ "${status}" -eq 2 ]
}

@test "eval with a double-quoted git command is blocked" {
    run_hook 'eval "git push"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'cannot be verified inside eval'* ]]
}

@test "eval with a single-quoted git command is blocked" {
    run_hook "eval 'git push'"
    [ "${status}" -eq 2 ]
}

@test "source is blocked outright" {
    run_hook "source ./setup.sh"
    [ "${status}" -eq 2 ]
}

@test "a path-qualified bare git invocation is blocked" {
    run_hook "/usr/bin/git push"
    [ "${status}" -eq 2 ]
}

@test "a path-qualified hardened git invocation is allowed" {
    run_hook "/usr/bin/git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a relative-path bare git invocation is blocked" {
    run_hook "./git push"
    [ "${status}" -eq 2 ]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook "if true; then git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}

@test "an obfuscated git name is opaque to this hook (reject-obfuscated-commands blocks it upstream)" {
    run_hook '"g""it" push'
    [ "${status}" -eq 0 ]
}
