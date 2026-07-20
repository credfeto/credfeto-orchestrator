#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/block-dotnet-tool-install"

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

@test "dotnet tool install (local) is blocked" {
    run_hook "dotnet tool install Foo.Bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "dotnet tool install --global is blocked" {
    run_hook "dotnet tool install --global Foo.Bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "dotnet tool install -g is blocked" {
    run_hook "dotnet tool install -g Foo.Bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "dotnet tool install --local is blocked" {
    run_hook "dotnet tool install --local Foo.Bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "dotnet new tool-manifest is blocked" {
    run_hook "dotnet new tool-manifest"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet new tool-manifest is prohibited'* ]]
}

@test "dotnet tool list is allowed" {
    run_hook "dotnet tool list -g"
    [ "${status}" -eq 0 ]
}

@test "dotnet tool restore is allowed" {
    run_hook "dotnet tool restore"
    [ "${status}" -eq 0 ]
}

@test "dotnet tool uninstall is allowed" {
    run_hook "dotnet tool uninstall -g Foo.Bar"
    [ "${status}" -eq 0 ]
}

@test "dotnet tool update is allowed" {
    run_hook "dotnet tool update -g Foo.Bar"
    [ "${status}" -eq 0 ]
}

@test "dotnet tool run is allowed" {
    run_hook "dotnet tool run Foo.Bar"
    [ "${status}" -eq 0 ]
}

@test "dotnet new console (unrelated template) is allowed" {
    run_hook "dotnet new console"
    [ "${status}" -eq 0 ]
}

@test "dotnet build is allowed" {
    run_hook "dotnet build"
    [ "${status}" -eq 0 ]
}

@test "dotnet tool with no subcommand is allowed" {
    run_hook "dotnet tool"
    [ "${status}" -eq 0 ]
}

@test "dotnet new with no template is allowed" {
    run_hook "dotnet new"
    [ "${status}" -eq 0 ]
}

@test "dotnet alone with no subcommand is allowed" {
    run_hook "dotnet"
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation followed by a bare tool install via && is blocked" {
    run_hook "dotnet build && dotnet tool install -g Foo.Bar"
    [ "${status}" -eq 2 ]
}

@test "a hardened invocation followed by a bare tool restore via && is allowed" {
    run_hook "dotnet build && dotnet tool restore"
    [ "${status}" -eq 0 ]
}

@test "a bare tool install prefixed with sudo is blocked" {
    run_hook "sudo dotnet tool install -g Foo.Bar"
    [ "${status}" -eq 2 ]
}

@test "a bare tool-manifest prefixed with sudo is blocked" {
    run_hook "sudo dotnet new tool-manifest"
    [ "${status}" -eq 2 ]
}

@test "a path-qualified dotnet tool install invocation is blocked" {
    run_hook "/usr/bin/dotnet tool install -g Foo.Bar"
    [ "${status}" -eq 2 ]
}

@test "a command substitution invoking tool install is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'x=$(dotnet tool install -g Foo.Bar)'
    [ "${status}" -eq 2 ]
}

@test "an unrelated command mentioning tool install in an argument is allowed" {
    run_hook 'grep -r "tool install" .'
    [ "${status}" -eq 0 ]
}

@test "a non-dotnet command mentioning dotnet tool install is allowed" {
    run_hook 'echo "please avoid dotnet tool install"'
    [ "${status}" -eq 0 ]
}

@test "eval wrapping a tool install command is opaque to this hook (eval is already blocked upstream by enforce-git-dash-c/command-blocklist)" {
    run_hook 'eval "dotnet tool install -g Foo.Bar"'
    [ "${status}" -eq 0 ]
}

@test "a non-dotnet command is allowed" {
    run_hook "ls -la"
    [ "${status}" -eq 0 ]
}

@test "heredoc body text that merely looks like a tool install command is not blocked" {
    run_hook "$(printf 'cat <<EOF\ndotnet tool install -g Foo.Bar\nEOF')"
    [ "${status}" -eq 0 ]
}

@test "an obfuscated tool install argument is opaque to this hook (reject-obfuscated-commands blocks it upstream)" {
    run_hook 'dotnet "tool" install -g Foo.Bar'
    [ "${status}" -eq 0 ]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook "if true; then dotnet tool install"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}
