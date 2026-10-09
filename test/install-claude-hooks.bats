#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034  # bats test bodies run in subshells; variable modifications are intentionally scoped and read by the sourced main()

load test_helper

setup() {
    setup_isolated_env
    # Read when the script is sourced, so they must be exported first: without them main would
    # install cfwf into the real /usr/local/bin and the managed files into the real /etc.
    export CFWF_BIN_DIR="${TEST_TMP}/bin"
    export CLAUDE_MANAGED_DIR="${TEST_TMP}/etc/claude-code"
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

# Replaces the declining sudo stub with one that logs the command and then runs it without its
# `-o root -g root` ownership options, which only root could apply: the files land under TEST_TMP
# owned by the test user, and SUDO_LOG records that root ownership was asked for.
allow_sudo() {
    # shellcheck disable=SC2016
    make_stub_multiline sudo \
        'printf "%s\n" "$*" >> "${SUDO_LOG}"' \
        'args=()' \
        'while [ "$#" -gt 0 ]; do case "$1" in -o | -g) shift 2 ;; *) args+=("$1"); shift ;; esac; done' \
        'exec "${args[@]}"'
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

# --- managed files: root-owned copies under CLAUDE_MANAGED_DIR ----------------

@test "main copies every file in the repo's claude-hooks dir into the managed hooks dir, not as symlinks" {
    allow_sudo
    main

    local src name target
    while IFS= read -r src; do
        name=$(basename "${src}")
        target="${CLAUDE_MANAGED_DIR}/hooks/${name}"
        [ -f "${target}" ] || { echo "missing ${name}" >&2; return 1; }
        [ ! -L "${target}" ] || { echo "${name} is a symlink" >&2; return 1; }
        diff "${src}" "${target}" || { echo "${name} differs from its source" >&2; return 1; }
    done < <(find "${SOURCE_HOOKS_DIR}" -mindepth 1 -maxdepth 1 -type f ! -name allowed-dirs.local)
}

@test "hook scripts are installed 0755 and data files 0444" {
    allow_sudo
    main

    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/enforce-git-dash-c")" = "755" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/block-claude-config-writes")" = "755" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/command-allowlist")" = "444" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs")" = "444" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks")" = "755" ]
}

@test "no extra files beyond what's in the repo's claude-hooks dir" {
    allow_sudo
    main

    local expected actual
    expected=$(find "${SOURCE_HOOKS_DIR}" -mindepth 1 -maxdepth 1 -type f ! -name allowed-dirs.local -printf '%f\n' | sort)
    actual=$(find "${CLAUDE_MANAGED_DIR}/hooks" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    [ "${expected}" = "${actual}" ]
}

@test "an allowed-dirs.local left in the checkout's claude-hooks dir is never installed" {
    allow_sudo
    SOURCE_HOOKS_DIR="${TEST_TMP}/claude-hooks"
    cp -r "${REPO_DIR}/containers/base/development-full/claude-hooks" "${SOURCE_HOOKS_DIR}"
    printf '/\n' > "${SOURCE_HOOKS_DIR}/allowed-dirs.local"
    main

    [ -f "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs" ]
    [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local" ]
    run grep -c 'allowed-dirs.local' "${SUDO_LOG}"
    [ "${output}" = "0" ]
}

@test "the managed settings are installed verbatim, read-only, as managed-settings.json" {
    allow_sudo
    main

    diff "${SOURCE_MANAGED_SETTINGS}" "${CLAUDE_MANAGED_DIR}/managed-settings.json"
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/managed-settings.json")" = "444" ]
    run jq empty "${CLAUDE_MANAGED_DIR}/managed-settings.json"
    [ "${status}" -eq 0 ]
}

@test "every managed-dir install is run through sudo as root:root" {
    allow_sudo
    main

    grep -qxF "install -o root -g root -d -m 0755 ${CLAUDE_MANAGED_DIR} ${CLAUDE_MANAGED_DIR}/hooks" "${SUDO_LOG}"
    grep -qxF "install -o root -g root -m 0755 ${SOURCE_HOOKS_DIR}/enforce-git-dash-c ${CLAUDE_MANAGED_DIR}/hooks/enforce-git-dash-c" "${SUDO_LOG}"
    grep -qxF "install -o root -g root -m 0444 ${SOURCE_HOOKS_DIR}/command-allowlist ${CLAUDE_MANAGED_DIR}/hooks/command-allowlist" "${SUDO_LOG}"
    grep -qxF "install -o root -g root -m 0444 ${SOURCE_MANAGED_SETTINGS} ${CLAUDE_MANAGED_DIR}/managed-settings.json" "${SUDO_LOG}"
    run grep -vc '^install -o root -g root ' "${SUDO_LOG}"
    [ "${output}" = "0" ]
}

@test "the managed files are never installed without sudo, even when the directory is writable" {
    mkdir -p "${CLAUDE_MANAGED_DIR}/hooks"
    run main
    [ "${status}" -eq 0 ]
    [ ! -e "${CLAUDE_MANAGED_DIR}/managed-settings.json" ]
    [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/enforce-git-dash-c" ]
}

@test "when sudo is declined, main asks once, prints every root install command and still installs the user settings" {
    run main
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${SUDO_LOG}")" -eq 1 ]
    [[ "${output}" == *'no guardrails are active until you run:'* ]]
    [[ "${output}" == *"sudo install -o root -g root -m 0444 ${SOURCE_MANAGED_SETTINGS} ${CLAUDE_MANAGED_DIR}/managed-settings.json"* ]]
    [[ "${output}" == *"sudo install -o root -g root -m 0755 ${SOURCE_HOOKS_DIR}/enforce-git-dash-c ${CLAUDE_MANAGED_DIR}/hooks/enforce-git-dash-c"* ]]
    diff "${SOURCE_USER_SETTINGS}" "${HOME}/.claude/settings.json"
}

@test "when sudo is not installed, main prints every root install command and still installs the user settings" {
    hide_tools sudo
    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${SUDO_LOG}" ]
    [[ "${output}" == *"sudo install -o root -g root -m 0444 ${SOURCE_MANAGED_SETTINGS} ${CLAUDE_MANAGED_DIR}/managed-settings.json"* ]]
    diff "${SOURCE_USER_SETTINGS}" "${HOME}/.claude/settings.json"
}

@test "when sudo is declined, an existing settings.json and the old hook symlinks are left as they were" {
    mkdir -p "${HOME}/.claude/hooks"
    printf '{"permissions":{"deny":["Bash(rm *)"]}}\n' > "${HOME}/.claude/settings.json"
    ln -s "${SOURCE_HOOKS_DIR}/enforce-git-dash-c" "${HOME}/.claude/hooks/enforce-git-dash-c"
    run main
    [ "${status}" -eq 0 ]
    [ "$(cat "${HOME}/.claude/settings.json")" = '{"permissions":{"deny":["Bash(rm *)"]}}' ]
    [ ! -e "${HOME}/.claude/settings.json.bak" ]
    [ -L "${HOME}/.claude/hooks/enforce-git-dash-c" ]
    [[ "${output}" == *"Left ${HOME}/.claude/settings.json and ${HOME}/.claude/hooks as they were"* ]]
}

# --- legacy ~/.claude/hooks symlinks -------------------------------------------

@test "stale ~/.claude/hooks symlinks into the checkout are removed, anything else there is kept" {
    allow_sudo
    mkdir -p "${HOME}/.claude/hooks" "${TEST_TMP}/elsewhere"
    ln -s "${SOURCE_HOOKS_DIR}/enforce-git-dash-c" "${HOME}/.claude/hooks/enforce-git-dash-c"
    ln -s "${SOURCE_HOOKS_DIR}/allowed-dirs" "${HOME}/.claude/hooks/allowed-dirs"
    printf '%s\n' "${HOME}/work" > "${HOME}/.claude/hooks/allowed-dirs.local"
    printf 'x' > "${TEST_TMP}/elsewhere/mine"
    ln -s "${TEST_TMP}/elsewhere/mine" "${HOME}/.claude/hooks/mine"

    run main
    [ "${status}" -eq 0 ]
    [ ! -e "${HOME}/.claude/hooks/enforce-git-dash-c" ]
    [ ! -L "${HOME}/.claude/hooks/allowed-dirs" ]
    [ -f "${HOME}/.claude/hooks/allowed-dirs.local" ]
    [ -L "${HOME}/.claude/hooks/mine" ]
    [[ "${output}" == *"Removed stale symlink ${HOME}/.claude/hooks/enforce-git-dash-c"* ]]
}

# --- allowed-dirs.local --------------------------------------------------------

@test "an allowed-dirs file argument is installed via sudo as the root-owned allowed-dirs.local" {
    allow_sudo
    printf '%s\n' "${HOME}/work" > "${TEST_TMP}/my-dirs"
    run main "${TEST_TMP}/my-dirs"
    [ "${status}" -eq 0 ]
    diff "${TEST_TMP}/my-dirs" "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local"
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local")" = "444" ]
    grep -qxF "install -o root -g root -m 0444 ${TEST_TMP}/my-dirs ${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local" "${SUDO_LOG}"
    [[ "${output}" != *'will block every directory-taking command'* ]]
}

@test "a relative allowed-dirs file argument is installed by its absolute path" {
    allow_sudo
    printf '%s\n' "${HOME}/work" > "${TEST_TMP}/my-dirs"
    cd "${TEST_TMP}"
    run main my-dirs
    [ "${status}" -eq 0 ]
    grep -qxF "install -o root -g root -m 0444 ${TEST_TMP}/my-dirs ${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local" "${SUDO_LOG}"
}

@test "a missing allowed-dirs file argument is fatal before anything is installed" {
    allow_sudo
    run main "${TEST_TMP}/no-such-file"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'Allowed directories file not found'* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

@test "with no argument and no allowed-dirs.local, main warns rather than fabricating one" {
    allow_sudo
    run main
    [ "${status}" -eq 0 ]
    [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local" ]
    [[ "${output}" == *"No ${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local found"* ]]
}

@test "an already installed allowed-dirs.local is left alone and not warned about" {
    allow_sudo
    mkdir -p "${CLAUDE_MANAGED_DIR}/hooks"
    printf '%s\n' "${HOME}/work" > "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local"
    run main
    [ "${status}" -eq 0 ]
    [ "$(cat "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local")" = "${HOME}/work" ]
    [[ "${output}" != *'will block every directory-taking command'* ]]
}

# --- user settings -------------------------------------------------------------

@test "the user settings are copied verbatim to ~/.claude/settings.json" {
    main

    diff "${SOURCE_USER_SETTINGS}" "${HOME}/.claude/settings.json"
    run jq empty "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
}

@test "the user settings hold preferences only - nothing that governs permissions, hooks or MCP servers" {
    local keys
    keys=$(jq -r 'keys[]' "${SOURCE_USER_SETTINGS}" | sort | tr '\n' ' ')
    [ "${keys}" = "advisorModel agent agentPushNotifEnabled attribution autoCompactEnabled autoMemoryEnabled env includeGitInstructions model outputStyle remoteControlAtStartup theme tui " ]
}

@test "a pre-existing settings.json is preserved as settings.json.bak" {
    mkdir -p "${HOME}/.claude"
    printf '{"marker": "pre-existing"}' > "${HOME}/.claude/settings.json"
    allow_sudo

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
    allow_sudo
    main
    main

    run jq empty "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
    diff "${SOURCE_HOOKS_DIR}/enforce-git-dash-c" "${CLAUDE_MANAGED_DIR}/hooks/enforce-git-dash-c"
}

# --- the shipped managed settings ------------------------------------------------

@test "the managed settings lock out every other settings source and disable bypass mode" {
    run jq -r '[.allowManagedPermissionRulesOnly, .allowManagedHooksOnly, .allowManagedMcpServersOnly, .permissions.disableBypassPermissionsMode, .permissions.defaultMode] | map(tostring) | join(" ")' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "true true true disable dontAsk" ]
}

@test "every managed hook command is an absolute /etc/claude-code/hooks path, apart from block-no-verify" {
    local cmd
    while IFS= read -r cmd; do
        [ "${cmd}" = "block-no-verify" ] && continue
        [[ "${cmd}" == /etc/claude-code/hooks/* ]] || { echo "not an /etc/claude-code/hooks path: ${cmd}" >&2; return 1; }
    done < <(jq -r '.hooks.PreToolUse[].hooks[].command' "${SOURCE_MANAGED_SETTINGS}")
}

@test "every hook the managed settings run exists in claude-hooks and is copied into /etc/claude-code/hooks by the Dockerfile" {
    local dockerfile="${SOURCE_DIR}/Dockerfile" name
    while IFS= read -r name; do
        [ -x "${SOURCE_HOOKS_DIR}/${name}" ] || { echo "no executable claude-hooks/${name}" >&2; return 1; }
        grep -qE "^COPY .* claude-hooks/${name} /etc/claude-code/hooks/${name}\$" "${dockerfile}" \
            || { echo "Dockerfile does not COPY ${name} into /etc/claude-code/hooks" >&2; return 1; }
    done < <(jq -r '.hooks.PreToolUse[].hooks[].command | select(startswith("/etc/claude-code/hooks/")) | ltrimstr("/etc/claude-code/hooks/")' "${SOURCE_MANAGED_SETTINGS}" | sort -u)
}

@test "the managed settings never ship a hardcoded /home/<user> path or the \$HOME token" {
    run grep -qE '/home/[^/[:space:]]+/\.claude' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 1 ]
    # shellcheck disable=SC2016  # literal $HOME - asserting the unexpanded token is absent
    run grep -qF '$HOME' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 1 ]
}

@test "the Bash chain runs enforce-allowed-dirs then block-claude-config-writes straight after reject-obfuscated-commands (#1385)" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0:3][] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/etc/claude-code/hooks/reject-obfuscated-commands
/etc/claude-code/hooks/enforce-allowed-dirs
/etc/claude-code/hooks/block-claude-config-writes" ]
}

@test "the Bash chain includes block-git-worktree, block-dotnet-tool-install and cache-gh-lookups (#1380)" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'/etc/claude-code/hooks/block-git-worktree'* ]]
    [[ "${output}" == *'/etc/claude-code/hooks/block-dotnet-tool-install'* ]]
    [[ "${output}" == *'/etc/claude-code/hooks/cache-gh-lookups'* ]]
}

@test "block-git-worktree is registered against the native EnterWorktree tool (#1322)" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "EnterWorktree") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/block-git-worktree' ]
}

@test "block-github-mcp-write-tools is registered against the mcp__github__.* matcher" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "mcp__github__.*") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/block-github-mcp-write-tools' ]
}

@test "block-claude-config-writes is registered against the Edit, Write and NotebookEdit tools" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|NotebookEdit") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/block-claude-config-writes' ]
}

@test "the repo's own .claude settings, .mcp.json and ~/.claude.json are denied to Edit by relative path" {
    local denies entry
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}")
    for entry in 'Edit(.claude/settings*.json*)' 'Edit(.mcp.json)' 'Edit(~/.claude.json)'; do
        printf '%s\n' "${denies}" | grep -qxF "${entry}" || { echo "missing deny ${entry}" >&2; return 1; }
    done
}

@test "every code-execution/destructive flag is denied in both the first and a later argument position (#1385)" {
    # `*` matches one-or-more characters, so `Bash(rm * --no-preserve-root*)` alone does not
    # match `rm --no-preserve-root -rf /` - each flag needs the pair. Pinned here so a new deny
    # cannot be added in only one position.
    local denies pair tool flag
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}")
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
    for exact in "Bash(rm -rf /)" "Bash(rm -fr /)" "Bash(rm -r -f /)" "Bash(rm -f -r /)" "Bash(rm * /)" \
        "Bash(node *..*)"; do
        printf '%s\n' "${denies}" | grep -qxF "${exact}" \
            || { echo "missing exact deny: ${exact}" >&2; return 1; }
    done
}

@test "node's code-loading flags are denied in the first argument position only" {
    # Every permissions.allow shape for node puts the .github/actions script path as node's first
    # positional argument (optionally after --check), and node stops parsing its own options there,
    # so a later -r/--require is a script argument, not a node flag. A later-position deny would
    # block legitimate script arguments such as -refresh for no gain; the first-position deny is
    # defence in depth in case the allow patterns ever change. (reject-obfuscated-commands still
    # rejects a script argument that looks like an inline-code flag, such as -e or -config.)
    local denies flag
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}")
    for flag in --experimental-loader --import --inspect --loader --require -r; do
        printf '%s\n' "${denies}" | grep -qxF "Bash(node ${flag}*)" \
            || { echo "missing first-position deny: Bash(node ${flag}*)" >&2; return 1; }
        if printf '%s\n' "${denies}" | grep -qxF "Bash(node * ${flag}*)"; then
            echo "unexpected later-position deny: Bash(node * ${flag}*)" >&2
            return 1
        fi
    done
    if printf '%s\n' "${denies}" | grep -qxF "Bash(node ..*)"; then
        echo "unexpected deny Bash(node ..*) - already covered by Bash(node *..*)" >&2
        return 1
    fi
}

# --- preconditions ---------------------------------------------------------------

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

@test "dies when the source managed settings are missing" {
    SOURCE_MANAGED_SETTINGS="${TEST_TMP}/does-not-exist.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source managed settings not found"* ]]
}

@test "dies when the source user settings are missing" {
    SOURCE_USER_SETTINGS="${TEST_TMP}/does-not-exist.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source user settings not found"* ]]
}

@test "dies before installing anything when the managed settings are not valid JSON" {
    allow_sudo
    printf '{ not json' > "${TEST_TMP}/broken.json"
    SOURCE_MANAGED_SETTINGS="${TEST_TMP}/broken.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Managed settings are not valid JSON"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
    [ ! -e "${HOME}/.claude/settings.json" ]
}

# --- cfwf ------------------------------------------------------------------------

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
    grep -qxF "install -m 0755 -o root -g root ${SOURCE_CFWF} ${CFWF_BIN_DIR}/cfwf" "${SUDO_LOG}"
}

@test "main does not use sudo for cfwf when the bin directory is writable" {
    allow_sudo
    run main
    [ "${status}" -eq 0 ]
    run grep -c 'cfwf' "${SUDO_LOG}"
    [ "${output}" = "0" ]
}

@test "when sudo is declined, main prints the cfwf sudo command to run and still installs the user settings" {
    CFWF_BIN_DIR="${TEST_TMP}/no/such/dir"
    run main
    [ "${status}" -eq 0 ]
    [ -f "${SUDO_LOG}" ]
    [[ "${output}" == *"Could not install cfwf to ${CFWF_BIN_DIR}/cfwf"* ]]
    [[ "${output}" == *"cannot create regular file"* ]]
    [[ "${output}" == *"sudo install -m 0755 -o root -g root ${SOURCE_CFWF} ${CFWF_BIN_DIR}/cfwf"* ]]
    run jq empty "${HOME}/.claude/settings.json"
    [ "${status}" -eq 0 ]
}

@test "when sudo is not installed, main prints the cfwf sudo command to run and still installs the user settings" {
    CFWF_BIN_DIR="${TEST_TMP}/no/such/dir"
    hide_tools sudo
    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${SUDO_LOG}" ]
    [[ "${output}" == *"Could not install cfwf to ${CFWF_BIN_DIR}/cfwf"* ]]
    [ -f "${HOME}/.claude/settings.json" ]
}

@test "dies when the source cfwf script is missing" {
    SOURCE_CFWF="${TEST_TMP}/does-not-exist"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source cfwf script not found"* ]]
}

# --- required tools --------------------------------------------------------------

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
    allow_sudo
    hide_tools shfmt
    run main
    [ "${status}" -eq 1 ]
    [ ! -e "${HOME}/.claude" ]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
    [ ! -e "${CFWF_BIN_DIR}/cfwf" ]
}
