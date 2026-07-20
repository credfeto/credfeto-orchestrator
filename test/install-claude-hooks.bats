#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034  # bats test bodies run in subshells; variable modifications are intentionally scoped and read by the sourced main()

load test_helper

setup() {
    setup_isolated_env
    source_install_claude_hooks
}

teardown() {
    cleanup_stubs
}

@test "main symlinks every file in the repo's claude-hooks dir into ~/.claude/hooks" {
    main

    local src name
    while IFS= read -r src; do
        name=$(basename "${src}")
        [ -L "${HOME}/.claude/hooks/${name}" ] || fail "missing symlink for ${name}"
    done < <(find "${SOURCE_HOOKS_DIR}" -mindepth 1 -maxdepth 1 -type f)
}

@test "symlink targets resolve to the exact repo source file" {
    main

    [ "$(readlink -f "${HOME}/.claude/hooks/block-git-worktree")" = "$(readlink -f "${SOURCE_HOOKS_DIR}/block-git-worktree")" ]
    [ "$(readlink -f "${HOME}/.claude/hooks/enforce-git-dash-c")" = "$(readlink -f "${SOURCE_HOOKS_DIR}/enforce-git-dash-c")" ]
}

@test "no extra symlinks beyond what's in the repo's claude-hooks dir" {
    main

    local expected actual
    expected=$(find "${SOURCE_HOOKS_DIR}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
    actual=$(find "${HOME}/.claude/hooks" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    [ "${expected}" = "${actual}" ]
}

@test "generated settings.json is valid JSON" {
    main

    run jq empty "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
}

@test "generated settings.json is copied verbatim with the literal \$HOME token, not rewritten" {
    main

    run jq -r '.hooks.PreToolUse[0].hooks[0].command' "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token shipped in settings.json, not a shell variable
    [[ "${output}" == '$HOME/.claude/hooks/'* ]]

    run grep -c '/home/developer' "${HOME}/.claude/settings.json"
    [ "${status}" -eq 1 ]

    diff "${SOURCE_SETTINGS}" "${HOME}/.claude/settings.json"
}

@test "the template claude-settings.json never ships a hardcoded /home/<user> path" {
    run grep -qE '/home/[^/[:space:]]+/\.claude' "${SOURCE_SETTINGS}"
    [ "${status}" -eq 1 ]

    run jq -r '.hooks.PreToolUse[0].hooks[0].command' "${SOURCE_SETTINGS}"
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token shipped in settings.json, not a shell variable
    [[ "${output}" == '$HOME/.claude/hooks/'* ]]
}

@test "generated settings.json includes block-git-worktree in the PreToolUse chain" {
    main

    run jq -r '.hooks.PreToolUse[0].hooks[] | .command' "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token shipped in settings.json, not a shell variable
    [[ "${output}" == *'$HOME/.claude/hooks/block-git-worktree'* ]]
}

@test "generated settings.json includes block-dotnet-tool-install in the PreToolUse chain" {
    main

    run jq -r '.hooks.PreToolUse[0].hooks[] | .command' "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token shipped in settings.json, not a shell variable
    [[ "${output}" == *'$HOME/.claude/hooks/block-dotnet-tool-install'* ]]
}

@test "a pre-existing settings.json is preserved as settings.json.bak" {
    mkdir -p "${HOME}/.claude"
    printf '{"marker": "pre-existing"}' > "${HOME}/.claude/settings.json"

    main

    [ -f "${HOME}/.claude/settings.json.bak" ]
    run jq -r '.marker' "${HOME}/.claude/settings.json.bak"
    [ "${output}" = "pre-existing" ]
}

@test "no settings.json.bak is created on a first-ever install" {
    main

    [ ! -f "${HOME}/.claude/settings.json.bak" ]
}

@test "re-running main is idempotent" {
    main
    main

    run jq empty "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    [ -L "${HOME}/.claude/hooks/enforce-git-dash-c" ]
}

@test "refuses to run inside a live Claude Code session" {
    CLAUDECODE=1
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must not be run inside a Claude Code session"* ]]
}

@test "dies when the source hooks directory is missing" {
    SOURCE_HOOKS_DIR="${TEST_TMP}/does-not-exist"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"hooks directory not found"* ]]
}

@test "dies when the source settings.json is missing" {
    SOURCE_SETTINGS="${TEST_TMP}/does-not-exist.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source settings not found"* ]]
}
