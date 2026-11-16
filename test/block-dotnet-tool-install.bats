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

@test "an allowed invocation followed by a bare tool install via && is blocked" {
    run_hook "dotnet --info && dotnet tool install -g Foo.Bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "an allowed invocation followed by a bare tool restore via && is allowed" {
    run_hook "dotnet --info && dotnet tool restore"
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

@test "eval wrapping a tool install command is opaque to this hook (eval is already blocked upstream by enforce-git-policy/command-blocklist)" {
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

@test "a quoted-but-static tool word is read as tool, so tool install is still blocked" {
    run_hook 'dotnet "tool" install -g Foo.Bar'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

# A backslash-escaped tab (tool\<TAB>install) is one word at runtime, so it is not the tool
# subcommand; shfmt keeps it as a single Lit holding the raw tab, which must not split into two
# tab-joined fields that read as `tool install`. The word is unresolved, so it fails closed.
@test "a backslash-escaped tab inside one word is not split into separate words" {
    run_hook $'dotnet tool\\\tinstall Foo.Bar'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'unresolved word in the subcommand position'* ]]
    [[ "${output}" != *'dotnet tool install is prohibited'* ]]
}

@test "a backslash-escaped letter inside the install word is blocked" {
    run_hook 'dotnet tool inst\all x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "a backslash-escaped letter inside the dotnet command name is blocked" {
    run_hook 'd\otnet tool install x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "a backslash-escaped letter inside the tool word is blocked" {
    run_hook 'dotnet t\ool install x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet tool install is prohibited'* ]]
}

@test "a backslash-escaped letter inside the tool-manifest template is blocked" {
    run_hook 'dotnet new tool-mani\fest'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet new tool-manifest is prohibited'* ]]
}

@test "a backslash-escaped letter inside an allowed tool subcommand is allowed" {
    run_hook 'dotnet tool rest\ore'
    [ "${status}" -eq 0 ]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook "if true; then dotnet tool install"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}

@test "the denial message states the command never ran (#1281)" {
    run_hook "dotnet tool install"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'command did not run'* ]]
}

@test "dotnet tool exec and execute are blocked, since they run a package the image does not pin" {
    local sub
    for sub in exec execute; do
        run_hook "dotnet tool ${sub} Foo.Bar"
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"dotnet tool ${sub} is prohibited"* ]]
    done
}

# --- commands the build-dotnet MCP server runs -----------------------------

@test "each subcommand the build-dotnet MCP server covers is blocked, naming the MCP tool to use" {
    local -A tool=(
        [build]='mcp__build-dotnet__build'
        [test]='mcp__build-dotnet__test'
        [restore]='mcp__build-dotnet__restore'
        [clean]='mcp__build-dotnet__buildtest'
        [cscleanup]='mcp__build-dotnet__cleanup'
        [buildcheck]='mcp__build-dotnet__buildcheck'
        [format]='mcp__build-dotnet__cleanup'
        [reportgenerator]='mcp__build-dotnet__coverage'
    )
    local sub
    for sub in "${!tool[@]}"; do
        run_hook "dotnet ${sub}"
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"dotnet ${sub} is not permitted"* ]]
        [[ "${output}" == *"${tool[$sub]}"* ]]
        [[ "${output}" == *'the Code Tester for tests and coverage'* ]]
        [[ "${output}" == *'if the build-dotnet server is not connected, stop and report it'* ]]
        run_hook "dotnet ${sub} src/App.slnx -c Release"
        [ "${status}" -eq 2 ]
    done
}

@test "dotnet format style is blocked like every other dotnet format form" {
    run_hook "dotnet format style src/App.slnx --verify-no-changes"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet format is not permitted'* ]]
}

@test "dotnet package search is blocked in favour of the package_versions tool" {
    run_hook "dotnet package search Foo.Bar --exact-match --format json"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'mcp__build-dotnet__package_versions'* ]]
}

@test "other dotnet package subcommands are left to the permission rules" {
    run_hook "dotnet package list"
    [ "${status}" -eq 0 ]
}

@test "a covered subcommand is blocked whatever shape the command takes" {
    local cmd
    # shellcheck disable=SC2016  # literal $(...) - must reach the hook unexpanded
    for cmd in \
        "cd src && dotnet build" \
        "cd src; dotnet test" \
        "git -C . status && dotnet restore" \
        "dotnet --info | dotnet buildcheck -solution x.slnx" \
        "FOO=1 dotnet build" \
        "sudo dotnet test" \
        "/usr/bin/dotnet build" \
        'x=$(dotnet test)' \
        'dotnet "build"' \
        "dotnet 'test'" \
        'dotnet bu\ild' \
        "dotnet dotnet-format"; do
        run_hook "${cmd}"
        if [ "${status}" -ne 2 ]; then
            echo "not blocked: ${cmd}" >&2
            return 1
        fi
    done
}

@test "an option before the subcommand is blocked, so it cannot reach a denied subcommand" {
    local cmd
    for cmd in "dotnet --diagnostics build" "dotnet -d test" "dotnet --roll-forward Major app.dll"; do
        run_hook "${cmd}"
        [ "${status}" -eq 2 ]
        [[ "${output}" == *'dotnet options before the subcommand are not permitted'* ]]
    done
}

@test "an option that is the whole dotnet command is allowed" {
    local cmd
    for cmd in "dotnet --info" "dotnet --version" "dotnet --list-sdks" "dotnet --list-runtimes" "dotnet -h"; do
        run_hook "${cmd}"
        [ "${status}" -eq 0 ]
    done
}

@test "an unresolved word in the dotnet subcommand position fails closed" {
    local cmd
    # shellcheck disable=SC2016  # literal expansions - must reach the hook unexpanded
    for cmd in 'dotnet $X' 'dotnet "$X"' "dotnet ''" 'dotnet $(echo build)'; do
        run_hook "${cmd}"
        [ "${status}" -eq 2 ]
        [[ "${output}" == *'unresolved word in the subcommand position'* ]]
    done
}

@test "dotnet tool run of a covered or denied tool is blocked, under either command name" {
    local name
    for name in buildcheck dotnet-buildcheck cscleanup dotnet-cscleanup reportgenerator dotnet-reportgenerator dotnet-format csharpier dotnet-csharpier; do
        run_hook "dotnet tool run ${name} --help"
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"dotnet tool run ${name} is not permitted"* ]]
        [[ "${output}" == *'mcp__build-dotnet__'* ]]
        run_hook "dotnet tool run --allow-roll-forward ${name}"
        [ "${status}" -eq 2 ]
    done
}

@test "ANSI-C, locale and mixed quoting in the subcommand position fail closed" {
    local cmd
    for cmd in $'dotnet $\'build\'' 'dotnet $"build"' 'dotnet "bu"ild'; do
        run_hook "${cmd}"
        [ "${status}" -eq 2 ]
        [[ "${output}" == *'unresolved word in the subcommand position'* ]]
    done
}

# Inside double quotes a backslash before a letter is kept, so "bu\ild" stays bu\ild at runtime.
@test "a double-quoted backslash word is not decoded, so it is not read as build" {
    run_hook 'dotnet "bu\ild"'
    [ "${status}" -eq 0 ]
}

@test "an unresolved dotnet package subcommand fails closed" {
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'dotnet package $X Foo.Bar'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'dotnet package search is not permitted'* ]]
}

@test "an unresolved dotnet tool subcommand or tool run name fails closed" {
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'dotnet tool $X Foo.Bar'
    [ "${status}" -eq 2 ]
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'dotnet tool run $X'
    [ "${status}" -eq 2 ]
}

@test "the dotnet commands the build-dotnet MCP server does not cover are allowed" {
    local cmd
    for cmd in \
        "dotnet buildversion --BuildNumber 1" \
        'dotnet changelog -a Fixed -m "the build and test steps"' \
        "dotnet code-analysis" \
        "dotnet dotnet-script run.csx" \
        "dotnet nuget list source" \
        "dotnet nuget locals all --list" \
        "dotnet pack src/App.slnx" \
        "dotnet publish src/App/App.csproj" \
        "dotnet run --project src/App -- test build" \
        "dotnet tool run changelog --lint" \
        "dotnet tool list -g" \
        "dotnet tsqllint db" \
        "grep -r 'dotnet build' docs" \
        "echo dotnet test"; do
        run_hook "${cmd}"
        if [ "${status}" -ne 0 ]; then
            echo "blocked: ${cmd}: ${output}" >&2
            return 1
        fi
    done
}
