#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/reject-obfuscated-commands"

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

@test "a plain bare command is allowed" {
    run_hook "git push"
    [ "${status}" -eq 0 ]
}

@test "a hardened git -C invocation is allowed" {
    run_hook "git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a non-git simple command is allowed" {
    run_hook "ls -la"
    [ "${status}" -eq 0 ]
}

@test "a whole-token double-quoted command name is blocked" {
    run_hook '"git" push'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not a simple, obvious command'* ]]
}

@test "a whole-token single-quoted command name is blocked" {
    run_hook "'git' push"
    [ "${status}" -eq 2 ]
}

@test "a leading single-quote-spliced command name is blocked" {
    run_hook "'g'it push"
    [ "${status}" -eq 2 ]
}

@test "a leading double-quote-spliced command name is blocked" {
    run_hook '"g"it push'
    [ "${status}" -eq 2 ]
}

@test "a mid-word empty double-quote splice is blocked" {
    run_hook 'gi""t push'
    [ "${status}" -eq 2 ]
}

@test "a backslash-escaped command name is blocked" {
    run_hook 'g\it push'
    [ "${status}" -eq 2 ]
}

@test "a command substitution used as the command name is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook '$(echo git) push'
    [ "${status}" -eq 2 ]
}

@test "a backtick substitution used as the command name is blocked" {
    # shellcheck disable=SC2016  # literal backticks — must reach the hook unexpanded
    run_hook '`echo git` push'
    [ "${status}" -eq 2 ]
}

@test "eval is rejected outright" {
    run_hook 'eval "git push"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'eval used for indirect'* ]]
}

@test "sudo is banned outright, even with a bare command after it" {
    run_hook "sudo git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'sudo is not permitted'* ]]
}

@test "a quote-spliced command name after sudo is blocked" {
    run_hook 'sudo "g""it" push'
    [ "${status}" -eq 2 ]
}

@test "env is banned outright, even with a bare command after it" {
    run_hook "env FOO=bar git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'env is not permitted'* ]]
}

@test "chained banned wrappers are blocked at the first banned name" {
    run_hook "sudo env exec command git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'sudo is not permitted'* ]]
}

@test "nice is banned outright, even with a bare command after it" {
    run_hook "nice -n 19 git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'nice is not permitted'* ]]
}

@test "command is banned outright, even with a bare command after it" {
    run_hook "command -p git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'command is not permitted'* ]]
}

@test "env -i quote-spliced target is blocked (round 7 bypass)" {
    run_hook 'env -i "g""it" push --force'
    [ "${status}" -eq 2 ]
}

@test "nice -n quote-spliced target is blocked (round 7 bypass)" {
    run_hook 'nice -n 19 "g""it" push --force'
    [ "${status}" -eq 2 ]
}

@test "command -p quote-spliced target is blocked (round 7 bypass)" {
    run_hook 'command -p "g""it" push'
    [ "${status}" -eq 2 ]
}

@test "a wrapper's own leading flag is not mistaken for the command name (remaining wrappers)" {
    run_hook 'stdbuf -oL "g""it" push'
    [ "${status}" -eq 2 ]
}

@test "sudo with a leading flag before a quote-spliced target is blocked" {
    run_hook 'sudo -u root "g""it" push'
    [ "${status}" -eq 2 ]
}

@test "a negated bare command is allowed" {
    run_hook "! git push"
    # bare "git" after "!" is not obfuscated — only downstream hooks care about -C
    [ "${status}" -eq 0 ]
}

@test "a variable assignment prefix before a bare command is allowed" {
    run_hook 'FOO=bar git push'
    [ "${status}" -eq 0 ]
}

@test "output-capturing command substitution assigned to a variable is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'push_output=$(git -C /path push --force-with-lease 2>&1) || true'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation chained after a variable-assigned substitution is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'x=$(git -C . rev-parse HEAD)'
    [ "${status}" -eq 0 ]
}

@test "a bare command piped from another bare command is allowed" {
    run_hook "true | git push"
    [ "${status}" -eq 0 ]
}

@test "a bare command inside a for-loop do body is allowed" {
    run_hook "for i in 1; do git push; done"
    [ "${status}" -eq 0 ]
}

@test "a path-qualified binary is matched by basename against the allowlist" {
    run_hook "/usr/bin/git push"
    [ "${status}" -eq 0 ]
}

@test "a relative-path binary is matched by basename against the allowlist" {
    run_hook "./git push"
    [ "${status}" -eq 0 ]
}

@test "a path-qualified binary with an unknown basename is blocked" {
    run_hook "/tmp/mystery-tool --run"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the known-good command allowlist'* ]]
}

@test "a quoted argument containing metacharacters is not falsely blocked" {
    run_hook 'git -C . log --grep="(WIP) git stuff"'
    [ "${status}" -eq 0 ]
}

@test "a quoted commit message containing braces is not falsely blocked" {
    run_hook 'git -C . commit -m "wip {git}"'
    [ "${status}" -eq 0 ]
}

@test "a single-quoted argument containing an ampersand is not falsely blocked" {
    run_hook "git -C . commit -m 'stuff & things'"
    [ "${status}" -eq 0 ]
}

@test "a non-git command containing parens in a quoted argument is not falsely blocked" {
    run_hook 'echo "(git is great)"'
    [ "${status}" -eq 0 ]
}

@test "the standard heredoc commit-message idiom is not falsely blocked" {
    # shellcheck disable=SC2016  # literal $(...) in the printf format — must reach the hook unexpanded
    run_hook "$(printf 'git commit -m "$(cat <<%s\nCommit message here.\n%s\n)"' "'EOF'" "EOF")"
    [ "${status}" -eq 0 ]
}

@test "the standard heredoc gh comment-body idiom is not falsely blocked" {
    # shellcheck disable=SC2016  # literal $(...) in the printf format — must reach the hook unexpanded
    run_hook "$(printf 'gh pr comment 1 --repo o/r --body "$(cat <<COMMENT\nhello\n%s\n)"' "COMMENT")"
    [ "${status}" -eq 0 ]
}

@test "heredoc body text that merely looks like a bare git command is not blocked" {
    run_hook "$(printf 'cat <<EOF\ngit push\nEOF')"
    [ "${status}" -eq 0 ]
}

@test "IFS word-splitting to reconstruct a bare git invocation is blocked" {
    # shellcheck disable=SC2016  # literal ${IFS} — must reach the hook unexpanded
    run_hook 'git${IFS}push'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not a simple, obvious command'* ]]
}

@test "brace-expansion to reconstruct a bare git invocation is blocked" {
    run_hook '{git,push}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not a simple, obvious command'* ]]
}

@test "brace-expansion used as the command name after a wrapper is blocked" {
    run_hook 'sudo {git,push}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'sudo is not permitted'* ]]
}

@test "a bare variable used as the command name is blocked" {
    # shellcheck disable=SC2016  # literal $ALIAS — must reach the hook unexpanded
    run_hook '$ALIAS push'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not a simple, obvious command'* ]]
}

@test "a hardened compound group with no brace expansion is not falsely blocked" {
    run_hook '{ git -C . push; }'
    [ "${status}" -eq 0 ]
}

@test "brace expansion in argument position is not falsely blocked" {
    run_hook 'mkdir -p project/{src,test,docs}'
    [ "${status}" -eq 0 ]
}

@test "brace expansion in argument position after a hardened git invocation is not falsely blocked" {
    run_hook 'git -C . log --grep="{WIP,TODO}"'
    [ "${status}" -eq 0 ]
}

@test "a redirection operator preceding a quote-spliced command name is blocked" {
    run_hook '2>/dev/null "g""it" push --force'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not a simple, obvious command'* ]]
}

@test "bash -c with an inline git invocation is blocked" {
    run_hook 'bash -c "git push"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'interpreter re-invocation'* ]]
}

@test "sh -c with an inline git invocation is blocked" {
    run_hook 'sh -c "git push"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'interpreter re-invocation'* ]]
}

@test "python3 -c with inline code is blocked" {
    run_hook "python3 -c \"import os; os.system('git push')\""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'interpreter re-invocation'* ]]
}

@test "perl -e with inline code is blocked" {
    run_hook "perl -e \"system('git push')\""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'interpreter re-invocation'* ]]
}

@test "an interpreter re-invocation after sudo is blocked (sudo ban fires first)" {
    run_hook 'sudo bash -c "git push"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'sudo is not permitted'* ]]
}

@test "sub-shells are banned outright even without an inline-code flag" {
    run_hook "bash ./scripts/deploy.sh"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'sub-shells are banned'* ]]
}

@test "running a script file with an allowlisted interpreter and no inline-code flag is allowed" {
    run_hook "python3 script.py"
    [ "${status}" -eq 0 ]
}

@test "an interpreter invoked with unrelated flags is not falsely blocked" {
    run_hook "python3 -m venv env"
    [ "${status}" -eq 0 ]
}

@test "a command containing a non-ASCII byte is blocked" {
    run_hook $'git -C . commit -m "caf\xc3\xa9"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'non-printable or non-ASCII'* ]]
}

@test "a command containing a control byte is blocked" {
    run_hook $'git -C . commit -m "wip\x01"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'non-printable or non-ASCII'* ]]
}

@test "a plain ASCII command is not falsely blocked by the printable check" {
    run_hook 'git -C . commit -m "plain ascii message"'
    [ "${status}" -eq 0 ]
}

@test "a non-ASCII byte inside a heredoc body is blocked (whole-command check)" {
    run_hook "$(printf 'cat <<EOF\ncaf\xc3\xa9\nEOF')"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'non-printable or non-ASCII'* ]]
}

# ---- strict allowlist (unknown commands are rejected) -----------------------

@test "an unknown command name is blocked by the allowlist" {
    run_hook "somerandomtool --help"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the known-good command allowlist'* ]]
}

@test "an unknown command inside a command substitution is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'x=$(mystery-tool)'
    [ "${status}" -eq 2 ]
}

# ---- additional banned wrappers ---------------------------------------------

@test "timeout is banned outright" {
    run_hook "timeout 5 git -C . push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'timeout is not permitted'* ]]
}

@test "xargs is banned outright" {
    run_hook "echo x | xargs rm"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'xargs is not permitted'* ]]
}

@test "source is banned outright" {
    run_hook "source ./setup.sh"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'executes a script in the current shell'* ]]
}

@test "dot-sourcing is banned outright" {
    run_hook ". ./setup.sh"
    [ "${status}" -eq 2 ]
}

# ---- structural rejections ---------------------------------------------------

@test "export of a variable is blocked (DeclClause)" {
    run_hook "export PATH=/tmp/evil"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'declare/export/local/readonly'* ]]
}

@test "declare is blocked (DeclClause)" {
    run_hook "declare -x FOO=bar"
    [ "${status}" -eq 2 ]
}

@test "defining a shell function is blocked" {
    run_hook 'f() { git push; }'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'defining shell functions'* ]]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook "if true; then git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}

@test "missing shfmt fails closed" {
    mkdir -p "${STUB_BIN}/noshfmt"
    ln -s "$(command -v jq)" "${STUB_BIN}/noshfmt/jq"
    ln -s "$(command -v bash)" "${STUB_BIN}/noshfmt/bash"
    ln -s "$(command -v cat)" "${STUB_BIN}/noshfmt/cat"
    local payload
    payload=$(jq -n --arg cmd 'ls' '{tool_input: {command: $cmd}}')
    run bash -c 'printf "%s" "$1" | PATH="$2" "$3"' _ "$payload" "${STUB_BIN}/noshfmt" "$HOOK"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'failing closed'* ]]
}

# ---- environment-variable assignment blocklist -------------------------------

@test "a benign per-command assignment prefix is allowed" {
    run_hook "GH_PAGER= gh pr view 1"
    [ "${status}" -eq 0 ]
}

@test "assigning PATH as a per-command prefix is blocked" {
    run_hook "PATH=/tmp/evil ls"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'assignment to PATH is not permitted'* ]]
}

@test "assigning IFS standalone is blocked" {
    run_hook "IFS=,"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'assignment to IFS is not permitted'* ]]
}

@test "assigning a GIT_* identity variable is blocked" {
    run_hook 'GIT_AUTHOR_NAME=evil git -C . commit -m x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'assignment to GIT_AUTHOR_NAME is not permitted'* ]]
}

@test "assigning GIT_CONFIG_GLOBAL is blocked" {
    run_hook 'GIT_CONFIG_GLOBAL=/tmp/cfg git -C . push'
    [ "${status}" -eq 2 ]
}

# ---- round-8 bypass classes (keyword prefix + obfuscation/eval) ---------------

@test "a quote-spliced command inside an if/then body is blocked (round 8)" {
    run_hook 'if true; then "g""it" push; fi'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not a simple, obvious command'* ]]
}

@test "a quote-spliced command inside a for-loop body is blocked (round 8)" {
    run_hook 'for i in 1; do "g""it" push; done'
    [ "${status}" -eq 2 ]
}

@test "eval inside a while-loop body is blocked (round 8)" {
    run_hook 'while true; do eval "git push"; break; done'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'eval used for indirect'* ]]
}
