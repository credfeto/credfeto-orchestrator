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

@test "generated settings.json includes enforce-allowed-dirs immediately after reject-obfuscated-commands in the PreToolUse chain (#1385)" {
    main

    run jq -r '.hooks.PreToolUse[0].hooks[1].command' "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token shipped in settings.json, not a shell variable
    [ "${output}" = '$HOME/.claude/hooks/enforce-allowed-dirs' ]
}

@test "allowed-dirs is symlinked alongside the hooks and a missing allowed-dirs.local is called out, not fabricated (#1385)" {
    run main
    [ "${status}" -eq 0 ]
    [ -L "${HOME}/.claude/hooks/allowed-dirs" ]
    [ ! -e "${HOME}/.claude/hooks/allowed-dirs.local" ]
    [[ "${output}" == *'allowed-dirs.local'* ]]
}

@test "an existing allowed-dirs.local is left alone and not warned about (#1385)" {
    mkdir -p "${HOME}/.claude/hooks"
    printf '%s\n' "${HOME}/work" > "${HOME}/.claude/hooks/allowed-dirs.local"
    run main
    [ "${status}" -eq 0 ]
    [ ! -L "${HOME}/.claude/hooks/allowed-dirs.local" ]
    [ "$(cat "${HOME}/.claude/hooks/allowed-dirs.local")" = "${HOME}/work" ]
    [[ "${output}" != *'will block every directory-taking command'* ]]
}

@test "every code-execution/destructive flag is denied in both the first and a later argument position (#1385)" {
    # `*` matches one-or-more characters, so `Bash(rm * --no-preserve-root*)` alone does not
    # match `rm --no-preserve-root -rf /` - each flag needs the pair. Pinned here so a new deny
    # cannot be added in only one position.
    local denies pair tool flag
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_SETTINGS}")
    for pair in \
        "find:-delete" "find:-exec " "find:-execdir " "find:-fls " "find:-fprint" "find:-ok " "find:-okdir " \
        "git:--exec-path" "git:--git-dir" "git:--namespace" "git:--super-prefix" "git:--work-tree" \
        "npm:--globalconfig" "npm:--script-shell" "npm:--userconfig" \
        "rm:--no-preserve-root"; do
        tool="${pair%%:*}"
        flag="${pair#*:}"
        printf '%s\n' "${denies}" | grep -qxF "Bash(${tool} ${flag}*)" \
            || { echo "missing first-position deny: Bash(${tool} ${flag}*)" >&2; return 1; }
        printf '%s\n' "${denies}" | grep -qxF "Bash(${tool} * ${flag}*)" \
            || { echo "missing later-position deny: Bash(${tool} * ${flag}*)" >&2; return 1; }
    done
    for exact in "Bash(rm -rf /)" "Bash(rm -fr /)" "Bash(rm -r -f /)" "Bash(rm -f -r /)" "Bash(rm * /)"; do
        printf '%s\n' "${denies}" | grep -qxF "${exact}" \
            || { echo "missing exact deny: ${exact}" >&2; return 1; }
    done
}

@test "generated settings.json includes cache-gh-lookups in the PreToolUse chain (#1380)" {
    main

    run jq -r '.hooks.PreToolUse[0].hooks[] | .command' "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token shipped in settings.json, not a shell variable
    [[ "${output}" == *'$HOME/.claude/hooks/cache-gh-lookups'* ]]
}

@test "generated settings.json registers block-git-worktree against the native EnterWorktree tool (#1322)" {
    main

    run jq -r '.hooks.PreToolUse[] | select(.matcher == "EnterWorktree") | .hooks[] | .command' "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token shipped in settings.json, not a shell variable
    [[ "${output}" == '$HOME/.claude/hooks/block-git-worktree' ]]
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
