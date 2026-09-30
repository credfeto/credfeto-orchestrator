#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

# shellcheck disable=SC2034  # read by run_hook in test_helper.bash, not visible to shellcheck across `load`
HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-background-for-long-running-commands"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# run_hook (command, [run_in_background]) comes from the shared test_helper.bash.

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

@test "git commit with a non-literal -C argument is still blocked" {
    # shellcheck disable=SC2016  # literal $PWD - must reach the hook unexpanded
    run_hook 'git -C "$PWD" commit -m test'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git commit must run with run_in_background: true'* ]]
}

@test "git commit via an unresolved subcommand word is still blocked" {
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'git -C . $X commit -m test'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git commit must run with run_in_background: true'* ]]
}

@test "dotnet build via an unresolved argument right after dotnet is still blocked" {
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'dotnet $X build'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet <unresolved subcommand> must run with run_in_background: true'* ]]
}

@test "npm test via an unresolved argument right after npm is still blocked" {
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'npm $X'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'npm test'* ]]
}

@test "bun test via an unresolved argument right after bun is still blocked" {
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'bun $X'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bun test'* ]]
}

@test "a quoted-but-static dotnet subcommand with no expansion is not blocked" {
    run_hook 'dotnet "restore"'
    [ "${status}" -eq 0 ]
}

@test "a quoted-but-static npm subcommand with no expansion is not blocked" {
    run_hook 'npm "install"'
    [ "${status}" -eq 0 ]
}

@test "a quoted-but-static dotnet build is still blocked" {
    run_hook 'dotnet "build"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet build must run with run_in_background: true'* ]]
}

@test "an ANSI-C quoted dotnet subcommand still fails closed" {
    run_hook $'dotnet $\'build\''
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet <unresolved subcommand> must run with run_in_background: true'* ]]
}

@test "a Dollar-quoted double-quoted dotnet subcommand still fails closed" {
    run_hook 'dotnet $"build"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet <unresolved subcommand> must run with run_in_background: true'* ]]
}

@test "a single-quoted dotnet build is still blocked" {
    run_hook "dotnet 'build'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet build must run with run_in_background: true'* ]]
}

@test "a double-quoted single-backslash dotnet arg is not decoded and stays allowed" {
    run_hook 'dotnet "bu\ild"'
    [ "${status}" -eq 0 ]
}

@test "a double-quoted escaped dollar dotnet arg stays literal and allowed" {
    # shellcheck disable=SC2016  # literal \$build - must reach the hook unexpanded
    run_hook 'dotnet "\$build"'
    [ "${status}" -eq 0 ]
}

@test "an unquoted double-backslash dotnet arg decodes to bu\\ild, not build, and stays allowed" {
    run_hook 'dotnet bu\\ild'
    [ "${status}" -eq 0 ]
}

@test "a backslash-escaped dotnet build (bu\\ild) is blocked" {
    run_hook 'dotnet bu\ild'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet build must run with run_in_background: true'* ]]
}

@test "a backslash-escaped git commit (com\\mit) is blocked" {
    run_hook 'git -C . com\mit -m test'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git commit must run with run_in_background: true'* ]]
}

@test "a backslash-escaped npm test (t\\est) is blocked" {
    run_hook 'npm t\est'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'npm test must run with run_in_background: true'* ]]
}

@test "a backslash-escaped bun test (t\\est) is blocked" {
    run_hook 'bun t\est'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'bun test must run with run_in_background: true'* ]]
}

@test "dotnet with a single empty-string argument fails closed" {
    run_hook 'dotnet ""'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet <unresolved subcommand> must run with run_in_background: true'* ]]
}

@test "git commit preceded by a single-quoted arg with a real embedded tab byte is blocked" {
    run_hook "git -c 'x.y=a$(printf '\t')b' -C . commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git commit must run with run_in_background: true'* ]]
}

@test "git commit preceded by a double-quoted arg with a real embedded newline is blocked" {
    run_hook "git -c \"x.y=a$(printf '\n')b\" -C . commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git commit must run with run_in_background: true'* ]]
}

@test "a bare backslash-tab-escaped dotnet build (an embedded raw tab byte, #1530 vector-1) is blocked" {
    run_hook "dotnet bu\\$(printf '\t')ild"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet <unresolved subcommand> must run with run_in_background: true'* ]]
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

# --- pre-commit-check ------------------------------------------------------

@test "pre-commit-check without run_in_background is blocked" {
    run_hook "pre-commit-check"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'pre-commit-check must run with run_in_background: true'* ]]
}

@test "pre-commit-check with run_in_background true is allowed" {
    run_hook "pre-commit-check" true
    [ "${status}" -eq 0 ]
}

@test "a path-qualified pre-commit-check invocation is blocked" {
    run_hook "/home/user/bin/pre-commit-check"
    [ "${status}" -eq 2 ]
}

# --- buildtest -------------------------------------------------------------

@test "buildtest without run_in_background is blocked" {
    run_hook "buildtest"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'buildtest must run with run_in_background: true'* ]]
}

@test "buildtest with run_in_background true is allowed" {
    run_hook "buildtest" true
    [ "${status}" -eq 0 ]
}

@test "a command merely mentioning a bare-name-table entry as an argument is allowed" {
    run_hook "grep buildtest ."
    [ "${status}" -eq 0 ]
}

@test "a path-qualified buildtest invocation is blocked" {
    run_hook "/home/user/bin/buildtest"
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

@test "an obfuscated git commit argument is blocked here too, incidentally, by the fail-closed sentinel check (reject-obfuscated-commands still blocks it categorically upstream)" {
    run_hook 'git "com""mit" -m test'
    [ "${status}" -eq 2 ]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook "if true; then git commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}

@test "AST analysis failing after shfmt succeeds is blocked (fail closed, not fallen through as allowed)" {
    # Stub jq to fail only for the calls=$(... | jq ...) word-extraction pipeline
    # (identified by its literal_value program text), passing every other jq call
    # (raw_cmd, run_in_background) through to the real binary unchanged - the
    # calls=$(...) assignment must be guarded the same way the earlier ast=$(...)
    # assignment is, or a jq failure there silently falls through to `exit 0`
    # instead of blocking.
    local real_jq
    real_jq="$(command -v jq)"
    make_stub jq "case \"\$*\" in *literal_value*) exit 1 ;; esac; exec '${real_jq}' \"\$@\""
    run_hook "git commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'failing closed'* ]]
}

@test "an AST word with a Lit part but no Value key resolves opaque, not to a desyncing empty field (#1526 round 2)" {
    # Real shfmt never actually emits a Lit node without a Value key for any parseable
    # input, but literal_value must still fail closed on one rather than silently
    # reopening the word-index-desync bug this file already fixed once: a "" fallback
    # there resolves to a genuine (non-null) empty string, which is not caught by the
    # null check and not folded to the opaque marker, so it comes out as a real empty
    # tab field - collapsed away by IFS=<tab> word-splitting, shifting "commit" from
    # word index 3 down to index 2, past where the -c/-C skip loop below looks for it,
    # so the hook would no longer block. Stub shfmt to emit that exact AST shape
    # (git -C <no-Value> commit) directly, bypassing real shfmt's parser entirely.
    local ast_file="${TEST_TMP}/ast.json"
    printf '%s' '{"Type":"CallExpr","Args":[{"Parts":[{"Type":"Lit","Value":"git"}]},{"Parts":[{"Type":"Lit","Value":"-C"}]},{"Parts":[{"Type":"Lit"}]},{"Parts":[{"Type":"Lit","Value":"commit"}]}]}' > "${ast_file}"
    make_stub shfmt "cat '${ast_file}'"
    run_hook "git -C . commit -m test"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git commit must run with run_in_background: true'* ]]
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
