#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034  # bats test bodies run in subshells; variable modifications are intentionally scoped and read by the sourced main()

load test_helper

setup() {
    setup_isolated_env
    # Read when the script is sourced, so it must be exported first: without it main would
    # install cfwf into the real /usr/local/bin.
    export CFWF_BIN_DIR="${TEST_TMP}/bin"
    mkdir -p "${CFWF_BIN_DIR}"
    source_install_claude_hooks

    # main refuses to run without every tool the hooks need; stand in for any the host lacks so
    # these tests do not depend on what is installed where they run.
    local tool
    for tool in "${REQUIRED_TOOLS[@]}"; do
        command -v "${tool}" > /dev/null 2>&1 || make_stub "${tool}" 'exit 0'
    done

    # No test may reach the real sudo (it would prompt for a password): by default it is declined.
    export SUDO_LOG="${TEST_TMP}/sudo.log"
    # shellcheck disable=SC2016
    make_stub sudo 'printf "%s\n" "$*" >> "${SUDO_LOG}"; exit 1'
}

# Makes the named tools report as absent to the `command -v` presence check, deterministically and
# without altering the real system (the same override the install-timer and setup-owner suites use).
hide_tools() {
    HIDDEN_TOOLS=("$@")
    command() {
        local hidden
        if [ "$1" = "-v" ]; then
            for hidden in "${HIDDEN_TOOLS[@]}"; do
                [ "$2" = "${hidden}" ] && return 1
            done
        fi
        builtin command "$@"
    }
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
        "npm:-globalconfig" "npm:-script-shell" "npm:-userconfig" \
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

@test "main installs cfwf into the shared bin directory, executable by everyone" {
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Installed cfwf to ${CFWF_BIN_DIR}/cfwf"* ]]
    [ -x "${CFWF_BIN_DIR}/cfwf" ]
    [ ! -L "${CFWF_BIN_DIR}/cfwf" ]
    [ "$(stat -c '%a' "${CFWF_BIN_DIR}/cfwf")" = "755" ]
    diff "${SOURCE_CFWF}" "${CFWF_BIN_DIR}/cfwf"
}

@test "re-running main replaces an older installed cfwf" {
    printf '#!/bin/sh\necho stale\n' > "${CFWF_BIN_DIR}/cfwf"
    chmod 0644 "${CFWF_BIN_DIR}/cfwf"
    main
    diff "${SOURCE_CFWF}" "${CFWF_BIN_DIR}/cfwf"
    [ "$(stat -c '%a' "${CFWF_BIN_DIR}/cfwf")" = "755" ]
}

@test "when the bin directory is not writable, main installs cfwf with sudo as root:root" {
    CFWF_BIN_DIR="${TEST_TMP}/no/such/dir"
    # shellcheck disable=SC2016
    make_stub sudo 'printf "%s\n" "$*" >> "${SUDO_LOG}"; exit 0'
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"needs elevated permissions, running sudo"* ]]
    [[ "${output}" == *"Installed cfwf to ${CFWF_BIN_DIR}/cfwf (with sudo)"* ]]
    [ "$(cat "${SUDO_LOG}")" = "install -m 0755 -o root -g root ${SOURCE_CFWF} ${CFWF_BIN_DIR}/cfwf" ]
}

@test "main does not call sudo when the bin directory is writable" {
    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${SUDO_LOG}" ]
}

@test "when sudo is declined, main prints the sudo command to run and still installs everything else" {
    CFWF_BIN_DIR="${TEST_TMP}/no/such/dir"
    run main
    [ "${status}" -eq 0 ]
    [ -f "${SUDO_LOG}" ]
    [[ "${output}" == *"Could not install cfwf to ${CFWF_BIN_DIR}/cfwf"* ]]
    [[ "${output}" == *"sudo install -m 0755 -o root -g root ${SOURCE_CFWF} ${CFWF_BIN_DIR}/cfwf"* ]]
    [ -L "${HOME}/.claude/hooks/enforce-git-dash-c" ]
    run jq empty "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
}

@test "when sudo is not installed, main prints the sudo command to run and still installs everything else" {
    CFWF_BIN_DIR="${TEST_TMP}/no/such/dir"
    hide_tools sudo
    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${SUDO_LOG}" ]
    [[ "${output}" == *"Could not install cfwf to ${CFWF_BIN_DIR}/cfwf"* ]]
    [ -L "${HOME}/.claude/hooks/enforce-git-dash-c" ]
}

@test "dies when the source cfwf script is missing" {
    SOURCE_CFWF="${TEST_TMP}/does-not-exist"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source cfwf script not found"* ]]
}

@test "main aborts naming any single missing required tool" {
    local tool
    for tool in "${REQUIRED_TOOLS[@]}"; do
        hide_tools "${tool}"
        run main
        [ "${status}" -eq 1 ] || { echo "did not abort without ${tool}" >&2; return 1; }
        [[ "${output}" == *"Required tool(s) not found: ${tool}"* ]] || { echo "did not name ${tool}: ${output}" >&2; return 1; }
    done
}

@test "the required tools cover everything the hooks call" {
    local tool
    for tool in jq shfmt base64 realpath git gpg ssh-add sed grep; do
        printf '%s\n' "${REQUIRED_TOOLS[@]}" | grep -qxF "${tool}" \
            || { echo "REQUIRED_TOOLS is missing ${tool}" >&2; return 1; }
    done
}

@test "main names every missing required tool at once" {
    hide_tools shfmt gpg
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Required tool(s) not found: shfmt gpg"* ]]
}

@test "main installs nothing when a required tool is missing" {
    hide_tools shfmt
    run main
    [ "${status}" -eq 1 ]
    [ ! -e "${HOME}/.claude" ]
    [ ! -e "${CFWF_BIN_DIR}/cfwf" ]
}
