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
# without altering the real system (the same override the systemd-units and setup-owner suites use).
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
    done < <(find "${SOURCE_HOOKS_DIR}" -mindepth 1 -maxdepth 1 -type f ! -name allowed-dirs.local ! -name secret-files.local)
}

@test "hook scripts are installed 0755 and data files 0444" {
    allow_sudo
    main

    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/enforce-git-policy")" = "755" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/enforce-allowed-dirs")" = "755" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/command-allowlist")" = "444" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs")" = "444" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks")" = "755" ]
}

@test "no extra files beyond what's in the repo's claude-hooks dir" {
    allow_sudo
    main

    local expected actual
    expected=$(find "${SOURCE_HOOKS_DIR}" -mindepth 1 -maxdepth 1 -type f ! -name allowed-dirs.local ! -name secret-files.local -printf '%f\n' | sort)
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

@test "a secret-files.local left in the checkout's claude-hooks dir is never installed" {
    allow_sudo
    SOURCE_HOOKS_DIR="${TEST_TMP}/claude-hooks"
    cp -r "${REPO_DIR}/containers/base/development-full/claude-hooks" "${SOURCE_HOOKS_DIR}"
    printf 'nothing-matches-this\n' > "${SOURCE_HOOKS_DIR}/secret-files.local"
    main

    [ -f "${CLAUDE_MANAGED_DIR}/hooks/secret-files" ]
    [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/secret-files.local" ]
    run grep -c 'secret-files.local' "${SUDO_LOG}"
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

    grep -qxF "install -o root -g root -d -m 0755 ${CLAUDE_MANAGED_DIR} ${CLAUDE_MANAGED_DIR}/hooks ${CLAUDE_MANAGED_DIR}/mcp" "${SUDO_LOG}"
    grep -qxF "install -o root -g root -m 0755 ${SOURCE_HOOKS_DIR}/enforce-git-policy ${CLAUDE_MANAGED_DIR}/hooks/enforce-git-policy" "${SUDO_LOG}"
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
    [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/enforce-git-policy" ]
}

@test "when sudo is declined, main asks once, prints every root install command and still installs the user settings" {
    run main
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${SUDO_LOG}")" -eq 1 ]
    [[ "${output}" == *'no guardrails are active until you run:'* ]]
    [[ "${output}" == *"sudo install -o root -g root -m 0444 ${SOURCE_MANAGED_SETTINGS} ${CLAUDE_MANAGED_DIR}/managed-settings.json"* ]]
    [[ "${output}" == *"sudo install -o root -g root -m 0755 ${SOURCE_HOOKS_DIR}/enforce-git-policy ${CLAUDE_MANAGED_DIR}/hooks/enforce-git-policy"* ]]
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
    ln -s "${SOURCE_HOOKS_DIR}/enforce-git-policy" "${HOME}/.claude/hooks/enforce-git-policy"
    run main
    [ "${status}" -eq 0 ]
    [ "$(cat "${HOME}/.claude/settings.json")" = '{"permissions":{"deny":["Bash(rm *)"]}}' ]
    [ ! -e "${HOME}/.claude/settings.json.bak" ]
    [ -L "${HOME}/.claude/hooks/enforce-git-policy" ]
    [[ "${output}" == *"Left ${HOME}/.claude/settings.json and ${HOME}/.claude/hooks as they were"* ]]
}

# --- managed MCP servers: cfwf merged with the host's ~/.claude.json -----------

CFWF_URL='https://workflow-mcp.markridgwell.com/mcp'
KB_URL='https://memory.markridgwell.com/dev/mcp'

# Writes the given JSON as the host's ~/.claude.json.
write_host_claude_json() {
    printf '%s\n' "$1" > "${HOME}/.claude.json"
}

installed_mcp_names() {
    jq -r '.mcpServers | keys | join(" ")' "${CLAUDE_MANAGED_DIR}/managed-mcp.json"
}

# Prints the names the merge should install: the shipped servers, read from the shipped file so a
# server added there does not break these tests, plus the given host server names, sorted and
# joined as installed_mcp_names prints them.
expected_mcp_names() {
    { jq -r '.mcpServers | keys[]' "${SOURCE_MANAGED_MCP}"; printf '%s\n' "$@"; } \
        | sed '/^$/d' | LC_ALL=C sort -u | paste -sd ' ' -
}

@test "the headers helpers, the build-dotnet wrapper and managed-mcp.json are installed via sudo, 0755 and 0444" {
    allow_sudo
    main

    diff "${SOURCE_CFWF_MCP_HEADERS}" "${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers"
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers")" = "755" ]
    diff "${SOURCE_KB_MCP_HEADERS}" "${CLAUDE_MANAGED_DIR}/mcp/kb-mcp-headers"
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/mcp/kb-mcp-headers")" = "755" ]
    grep -qxF "install -o root -g root -m 0755 ${SOURCE_KB_MCP_HEADERS} ${CLAUDE_MANAGED_DIR}/mcp/kb-mcp-headers" "${SUDO_LOG}"
    diff "${SOURCE_BUILD_DOTNET_MCP}" "${CLAUDE_MANAGED_DIR}/mcp/build-dotnet-mcp"
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/mcp/build-dotnet-mcp")" = "755" ]
    grep -qxF "install -o root -g root -m 0755 ${SOURCE_BUILD_DOTNET_MCP} ${CLAUDE_MANAGED_DIR}/mcp/build-dotnet-mcp" "${SUDO_LOG}"
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "444" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/mcp")" = "755" ]
    grep -qxF "install -o root -g root -m 0755 ${SOURCE_CFWF_MCP_HEADERS} ${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers" "${SUDO_LOG}"
    grep -qxF "install -o root -g root -m 0444 ${HOME}/.claude/managed-mcp.merged.json ${CLAUDE_MANAGED_DIR}/managed-mcp.json" "${SUDO_LOG}"
}

@test "with no ~/.claude.json, managed-mcp.json holds the shipped servers alone, unchanged" {
    allow_sudo
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [ "$(jq -S . "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -S . "${SOURCE_MANAGED_MCP}")" ]
    [[ "${output}" == *"re-run this script after adding an MCP server there"* ]]
}

@test "an empty ~/.claude.json, or one with no MCP servers, installs the shipped servers alone" {
    allow_sudo
    : > "${HOME}/.claude.json"
    main
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]

    write_host_claude_json '{"projects": {"/x": {"allowedTools": []}}, "theme": "dark"}'
    main
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
}

@test "user-scope and every project's MCP servers are merged in beside cfwf" {
    allow_sudo
    write_host_claude_json '{
        "mcpServers": {"host-ide": {"type": "sse", "url": "http://localhost:64342/sse"}},
        "projects": {
            "/a": {"mcpServers": {"tool-a": {"type": "stdio", "command": "/usr/bin/tool-a", "args": ["--serve"]}}},
            "/b": {"mcpServers": {"tool-b": {"type": "http", "url": "https://b.example.com/mcp"}}}
        }
    }'
    main

    [ "$(installed_mcp_names)" = "$(expected_mcp_names host-ide tool-a tool-b)" ]
    [ "$(jq -c '.mcpServers.kb' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -c '.mcpServers.kb' "${SOURCE_MANAGED_MCP}")" ]
    [ "$(jq -r '.mcpServers["tool-a"].args[0]' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "--serve" ]
    [ "$(jq -c '.mcpServers.cfwf' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -c '.mcpServers.cfwf' "${SOURCE_MANAGED_MCP}")" ]
    [ "$(jq -c '.mcpServers["build-dotnet"]' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -c '.mcpServers["build-dotnet"]' "${SOURCE_MANAGED_MCP}")" ]
}

@test "a host server at cfwf's URL is left out as a duplicate, and its removal is suggested" {
    allow_sudo
    write_host_claude_json "{\"projects\": {\"${HOME}\": {\"mcpServers\": {\"secure-api\": {\"type\": \"http\", \"url\": \"${CFWF_URL}/\", \"headers\": {\"Authorization\": \"Bearer ghp_hostsecret\"}}}}}}"
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [[ "${output}" == *"Left out secure-api from ${HOME}/.claude.json: same URL as cfwf"* ]]
    [[ "${output}" == *"Remove them from ${HOME}/.claude.json"* ]]
    [ "$(grep -c 'ghp_hostsecret' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
    [[ "${output}" != *'ghp_hostsecret'* ]]
}

@test "host servers at kb's URL, under kb's own name or another, are left out as duplicates rather than colliding" {
    allow_sudo
    write_host_claude_json "{
        \"mcpServers\": {\"kb\": {\"type\": \"http\", \"url\": \"${KB_URL}\", \"headers\": {\"Authorization\": \"Bearer \${KB_TOKEN}\"}}},
        \"projects\": {\"${HOME}\": {\"mcpServers\": {\"memory\": {\"type\": \"http\", \"url\": \"${KB_URL}/\"}, \"secure-api\": {\"type\": \"http\", \"url\": \"${CFWF_URL}\"}}}}
    }"
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [ "$(jq -c '.mcpServers.kb' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -c '.mcpServers.kb' "${SOURCE_MANAGED_MCP}")" ]
    [[ "${output}" == *"Left out kb, memory from ${HOME}/.claude.json: same URL as kb, which replaces them"* ]]
    [[ "${output}" == *"Left out secure-api from ${HOME}/.claude.json: same URL as cfwf, which replaces them"* ]]
    [[ "${output}" != *"used for two different servers"* ]]
}

@test "a host server at kb's URL with a literal header is left out, with a warning that names its field and never its value" {
    allow_sudo
    write_host_claude_json "{\"mcpServers\": {\"kb\": {\"type\": \"http\", \"url\": \"${KB_URL}\", \"headers\": {\"Authorization\": \"Bearer kb-literal-dup\"}}}}"
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [ "$(jq -c '.mcpServers.kb' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -c '.mcpServers.kb' "${SOURCE_MANAGED_MCP}")" ]
    [[ "${output}" == *"Left out kb from ${HOME}/.claude.json: same URL as kb, which replaces them"* ]]
    [[ "${output}" == *"WARNING: kb in ${HOME}/.claude.json, left out above, may hold a secret in plain text: a headers or env value holds literal text"* ]]
    [[ "${output}" != *'did not copy'* ]]
    [ "$(grep -c 'kb-literal-dup' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
    [ "$(grep -c 'kb-literal-dup' "${HOME}/.claude/managed-mcp.merged.json")" -eq 0 ]
    [[ "${output}" != *'kb-literal-dup'* ]]
}

@test "a host server with a literal header or env value is refused by name and never copied" {
    allow_sudo
    write_host_claude_json '{
        "mcpServers": {
            "leaky-header": {"type": "http", "url": "https://l.example.com/mcp", "headers": {"X-Api-Key": "sk-literal-header"}},
            "leaky-bearer": {"type": "http", "url": "https://m.example.com/mcp", "headers": {"Authorization": "Bearer sk-literal-bearer"}}
        },
        "projects": {"/p": {"mcpServers": {"leaky-env": {"type": "stdio", "command": "x", "env": {"API_KEY": "sk-literal-env"}}}}}
    }'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [[ "${output}" == *"WARNING: did not copy leaky-bearer, leaky-env, leaky-header from ${HOME}/.claude.json"* ]]
    [ "$(grep -c 'sk-literal' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
    [ "$(grep -c 'sk-literal' "${HOME}/.claude/managed-mcp.merged.json")" -eq 0 ]
    [[ "${output}" != *'sk-literal'* ]]
}

@test "a host server whose headers and env only reference variables is copied" {
    allow_sudo
    # shellcheck disable=SC2016  # literal ${VAR} references, for Claude Code to expand
    write_host_claude_json '{"mcpServers": {"by-ref": {"type": "http", "url": "https://r.example.com/mcp", "headers": {"Authorization": "Bearer ${R_TOKEN}", "X-Key": "${R_KEY}"}, "env": {"A": "${A}"}}}}'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names by-ref)" ]
    # shellcheck disable=SC2016
    [ "$(jq -r '.mcpServers["by-ref"].headers.Authorization' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = 'Bearer ${R_TOKEN}' ]
    [[ "${output}" != *'did not copy'* ]]
}

@test "a host server whose url carries userinfo or a query string is refused by name and never copied" {
    allow_sudo
    write_host_claude_json '{
        "mcpServers": {
            "url-userinfo": {"type": "http", "url": "https://someone:pw-literal-userinfo@u.example.com/mcp"},
            "url-user-only": {"type": "sse", "url": "http://tk-literal-user@v.example.com/sse"}
        },
        "projects": {"/p": {"mcpServers": {"url-query": {"type": "http", "url": "https://q.example.com/mcp?api_key=qs-literal-query"}}}}
    }'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [[ "${output}" == *"WARNING: did not copy url-query, url-user-only, url-userinfo from ${HOME}/.claude.json"* ]]
    [ "$(grep -c -- '-literal-' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
    [ "$(grep -c -- '-literal-' "${HOME}/.claude/managed-mcp.merged.json")" -eq 0 ]
    [[ "${output}" != *'-literal-'* ]]
}

@test "a host server whose command or args look like a credential is refused by name and never copied" {
    allow_sudo
    # Built from pieces so the fixture itself does not look like a real key.
    local access_key_id="AKIA""LITERALARG000000"
    write_host_claude_json "{
        \"mcpServers\": {
            \"args-env-style\": {\"type\": \"stdio\", \"command\": \"env\", \"args\": [\"GITHUB_TOKEN=literalarg-env\", \"server\"]},
            \"args-prefix\": {\"type\": \"stdio\", \"command\": \"server\", \"args\": [\"--org\", \"ghp_literalarg1\"]},
            \"args-flag-value\": {\"type\": \"stdio\", \"command\": \"server\", \"args\": [\"--token\", \"literalarg-flag\"]},
            \"args-flag-equals\": {\"type\": \"stdio\", \"command\": \"server\", \"args\": [\"--api-key=literalarg-equals\"]}
        },
        \"projects\": {\"/p\": {\"mcpServers\": {
            \"args-aws\": {\"type\": \"stdio\", \"command\": \"server\", \"args\": [\"${access_key_id}\"]},
            \"command-prefix\": {\"type\": \"stdio\", \"command\": \"sk-literalarg-command\"}
        }}}
    }"
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [[ "${output}" == *"WARNING: did not copy args-aws, args-env-style, args-flag-equals, args-flag-value, args-prefix, command-prefix from ${HOME}/.claude.json"* ]]
    [ "$(grep -c -e 'literalarg' -e 'LITERALARG' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
    [ "$(grep -c -e 'literalarg' -e 'LITERALARG' "${HOME}/.claude/managed-mcp.merged.json")" -eq 0 ]
    [[ "${output}" != *'literalarg'* ]]
    [[ "${output}" != *'LITERALARG'* ]]
}

@test "a host server with a clean url and args, or args that only reference variables, is copied" {
    allow_sudo
    # shellcheck disable=SC2016  # literal ${VAR} references, for Claude Code to expand
    write_host_claude_json '{"mcpServers": {
        "clean-url": {"type": "http", "url": "https://c.example.com/mcp/a@b"},
        "clean-args": {"type": "stdio", "command": "npx", "args": ["-y", "@scope/server", "--port", "3000", "--author", "me", "--token-file", "/run/secrets/t"]},
        "ref-args": {"type": "stdio", "command": "server", "args": ["--token", "${S_TOKEN}", "--api-key=${S_KEY}", "GITHUB_TOKEN=${GH}"]}
    }}'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names clean-args clean-url ref-args)" ]
    # shellcheck disable=SC2016
    [ "$(jq -r '.mcpServers["ref-args"].args[1]' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = '${S_TOKEN}' ]
    [[ "${output}" != *'did not copy'* ]]
}

@test "a ~/.claude.json bigger than the kernel's per-argument limit is still merged" {
    allow_sudo
    local padding
    padding=$(head -c 200000 /dev/zero | tr '\0' 'x')
    write_host_claude_json "{\"padding\": \"${padding}\", \"mcpServers\": {\"host-ide\": {\"type\": \"sse\", \"url\": \"http://localhost:64342/sse\"}}}"
    [ "$(stat -c '%s' "${HOME}/.claude.json")" -gt 131072 ]
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names host-ide)" ]
}

@test "the same server repeated in several scopes is installed once" {
    allow_sudo
    write_host_claude_json '{
        "mcpServers": {"host-ide": {"type": "sse", "url": "http://localhost:64342/sse"}},
        "projects": {"/a": {"mcpServers": {"host-ide": {"type": "sse", "url": "http://localhost:64342/sse"}}}}
    }'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names host-ide)" ]
}

@test "one name for two different host servers is fatal before anything is installed" {
    allow_sudo
    write_host_claude_json '{
        "mcpServers": {"tool": {"type": "http", "url": "https://one.example.com/mcp"}},
        "projects": {"/a": {"mcpServers": {"tool": {"type": "http", "url": "https://two.example.com/mcp"}}}}
    }'
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"used for two different servers"*": tool."* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
    [ ! -e "${HOME}/.claude" ]
}

@test "a host server named cfwf at another URL collides with the shipped one and is fatal" {
    allow_sudo
    write_host_claude_json '{"mcpServers": {"cfwf": {"type": "http", "url": "https://elsewhere.example.com/mcp"}}}'
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"used for two different servers"*": cfwf."* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

@test "a host server named build-dotnet with another definition collides with the shipped one and is fatal (#1818)" {
    allow_sudo
    write_host_claude_json '{"mcpServers": {"build-dotnet": {"type": "stdio", "command": "/usr/bin/other-build"}}}'
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"used for two different servers"*": build-dotnet."* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

# `codegraph install` writes this exact entry into a host's ~/.claude.json, so the shipped one must
# match it for the merge to treat the two as the same server.
@test "a host codegraph server as codegraph install writes it is installed once, and with another definition is fatal" {
    allow_sudo
    write_host_claude_json '{"mcpServers": {"codegraph": {"type": "stdio", "command": "codegraph", "args": ["serve", "--mcp"], "alwaysLoad": true}}}'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [ "$(jq -c '.mcpServers.codegraph' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -c '.mcpServers.codegraph' "${SOURCE_MANAGED_MCP}")" ]

    rm -rf "${CLAUDE_MANAGED_DIR}"
    write_host_claude_json '{"mcpServers": {"codegraph": {"type": "stdio", "command": "/usr/bin/other-codegraph", "args": ["serve", "--mcp"]}}}'
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"used for two different servers"*": codegraph."* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

# A literal env value is refused for what it is, not for looking like a secret: a plain path, with
# no secret-shaped key or value, is still left out, because managed-mcp.json is world-readable.
@test "a host server with a literal env value that does not look like a secret is still refused" {
    allow_sudo
    write_host_claude_json '{"mcpServers": {"host-build": {"type": "stdio", "command": "/usr/bin/host-build", "env": {"SOME_SETTING": "/srv/some/path"}}}}'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [[ "${output}" == *"WARNING: did not copy host-build from ${HOME}/.claude.json"* ]]
    [ "$(grep -c -e host-build -e /srv/some/path "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
}

@test "an invalid ~/.claude.json is fatal before anything is installed" {
    allow_sudo
    printf '{ not json' > "${HOME}/.claude.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${HOME}/.claude.json is not valid JSON"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
    [ ! -e "${HOME}/.claude" ]
    [ ! -e "${CFWF_BIN_DIR}/cfwf" ]
}

@test "dies before installing anything when the shipped managed MCP servers are not valid JSON" {
    allow_sudo
    printf '{ not json' > "${TEST_TMP}/broken.json"
    SOURCE_MANAGED_MCP="${TEST_TMP}/broken.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Managed MCP servers are not valid JSON"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

@test "dies when the shipped managed MCP servers or the headers helper are missing" {
    SOURCE_MANAGED_MCP="${TEST_TMP}/does-not-exist.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source managed MCP servers not found"* ]]

    SOURCE_MANAGED_MCP="${SOURCE_DIR}/claude-managed-mcp.json"
    SOURCE_CFWF_MCP_HEADERS="${TEST_TMP}/does-not-exist"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source MCP headers helper not found: ${TEST_TMP}/does-not-exist"* ]]
}

@test "dies when the kb headers helper is missing, before anything is installed" {
    allow_sudo
    SOURCE_KB_MCP_HEADERS="${TEST_TMP}/kb-does-not-exist"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source MCP headers helper not found: ${TEST_TMP}/kb-does-not-exist"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

@test "dies when the build-dotnet MCP wrapper is missing, before anything is installed" {
    allow_sudo
    SOURCE_BUILD_DOTNET_MCP="${TEST_TMP}/build-dotnet-does-not-exist"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source build-dotnet MCP wrapper not found: ${TEST_TMP}/build-dotnet-does-not-exist"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

@test "the installed managed-mcp.json holds kb at its URL with its helper, and no Authorization text" {
    allow_sudo
    main
    [ "$(jq -c '.mcpServers.kb' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "{\"type\":\"http\",\"url\":\"${KB_URL}\",\"headersHelper\":\"/etc/claude-code/mcp/kb-mcp-headers\"}" ]
    [ "$(grep -ci 'authorization' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
}

@test "with no kb token in the environment or the token file, a one-line note says how to set one" {
    allow_sudo
    unset KB_MCP_TOKEN
    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'No kb MCP token found' <<<"${output}")" -eq 1 ]
    [[ "${output}" == *"export KB_MCP_TOKEN where claude runs, or write the token to ${XDG_CONFIG_HOME}/kb-mcp/token (chmod 600)"* ]]
}

@test "no kb token note when KB_MCP_TOKEN is set, and the token is never printed" {
    allow_sudo
    export KB_MCP_TOKEN=kb_env_secret
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'No kb MCP token found'* ]]
    [[ "${output}" != *'kb_env_secret'* ]]
    [ "$(grep -rl 'kb_env_secret' "${CLAUDE_MANAGED_DIR}" "${HOME}/.claude" | wc -l)" -eq 0 ]
}

@test "no kb token note when a private token file you own exists, and it is neither read nor changed" {
    allow_sudo
    unset KB_MCP_TOKEN
    mkdir -p "${XDG_CONFIG_HOME}/kb-mcp"
    printf 'kb_file_secret\n' > "${XDG_CONFIG_HOME}/kb-mcp/token"
    chmod 600 "${XDG_CONFIG_HOME}/kb-mcp/token"
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'No kb MCP token found'* ]]
    [[ "${output}" != *'is not private'* ]]
    [[ "${output}" != *'kb_file_secret'* ]]
    [ "$(cat "${XDG_CONFIG_HOME}/kb-mcp/token")" = 'kb_file_secret' ]
    [ "$(stat -c '%a' "${XDG_CONFIG_HOME}/kb-mcp/token")" = "600" ]
}

@test "the kb token file is looked for under HOME/.config when XDG_CONFIG_HOME is unset" {
    allow_sudo
    unset KB_MCP_TOKEN XDG_CONFIG_HOME
    run main
    [[ "${output}" == *"write the token to ${HOME}/.config/kb-mcp/token (chmod 600)"* ]]
    mkdir -p "${HOME}/.config/kb-mcp"
    printf 'kb_file_secret\n' > "${HOME}/.config/kb-mcp/token"
    chmod 600 "${HOME}/.config/kb-mcp/token"
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'No kb MCP token found'* ]]
    [[ "${output}" != *'is not private'* ]]
}

@test "a kb token file others can read gives a one-line not-private note, and it is neither read nor changed" {
    allow_sudo
    unset KB_MCP_TOKEN
    mkdir -p "${XDG_CONFIG_HOME}/kb-mcp"
    printf 'kb_file_secret\n' > "${XDG_CONFIG_HOME}/kb-mcp/token"
    chmod 644 "${XDG_CONFIG_HOME}/kb-mcp/token"
    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'is not private' <<<"${output}")" -eq 1 ]
    [[ "${output}" == *"kb MCP token file ${XDG_CONFIG_HOME}/kb-mcp/token is not private - kb-mcp-headers refuses it until it is a regular file owned by you with mode 0600"* ]]
    [[ "${output}" != *'No kb MCP token found'* ]]
    [[ "${output}" != *'kb_file_secret'* ]]
    [ "$(cat "${XDG_CONFIG_HOME}/kb-mcp/token")" = 'kb_file_secret' ]
    [ "$(stat -c '%a' "${XDG_CONFIG_HOME}/kb-mcp/token")" = "644" ]
}

@test "a kb token file that is a symlink to a private file gives the not-private note" {
    allow_sudo
    unset KB_MCP_TOKEN
    mkdir -p "${XDG_CONFIG_HOME}/kb-mcp"
    printf 'kb_file_secret\n' > "${TEST_TMP}/real-token"
    chmod 600 "${TEST_TMP}/real-token"
    ln -s "${TEST_TMP}/real-token" "${XDG_CONFIG_HOME}/kb-mcp/token"
    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c "kb MCP token file ${XDG_CONFIG_HOME}/kb-mcp/token is not private" <<<"${output}")" -eq 1 ]
    [[ "${output}" != *'No kb MCP token found'* ]]
    [[ "${output}" != *'kb_file_secret'* ]]
}

@test "a kb token file that is a dangling symlink gives the not-private note, not the no-token note" {
    allow_sudo
    unset KB_MCP_TOKEN
    mkdir -p "${XDG_CONFIG_HOME}/kb-mcp"
    ln -s "${TEST_TMP}/no-such-token" "${XDG_CONFIG_HOME}/kb-mcp/token"
    run main
    [ "${status}" -eq 0 ]
    [ "$(grep -c "kb MCP token file ${XDG_CONFIG_HOME}/kb-mcp/token is not private" <<<"${output}")" -eq 1 ]
    [[ "${output}" != *'No kb MCP token found'* ]]
}

# Prints the find predicate (everything after the "${token_file}" argument) from each code line
# of the given file that tests the kb token file's privacy, skipping comment lines so prose that
# quotes the test cannot stand in for the code.
kb_token_privacy_predicates() {
    grep -v '^[[:space:]]*#' "$1" | grep -F -- '-prune -type f -user' | sed -nE 's/.*\$\(find "\$\{token_file\}" (.*)\)" \].*/\1/p'
}

@test "warn_if_no_kb_token's token file privacy test is a word-for-word copy of kb-mcp-headers' token_file_is_private" {
    local helper_predicate installer_predicate
    helper_predicate="$(kb_token_privacy_predicates "${REPO_ROOT}/containers/base/development-full/claude-mcp/kb-mcp-headers")"
    installer_predicate="$(kb_token_privacy_predicates "${REPO_ROOT}/install-claude-hooks")"
    [ "$(grep -c . <<<"${helper_predicate}")" -eq 1 ]
    [ "$(grep -c . <<<"${installer_predicate}")" -eq 1 ]
    [ "${installer_predicate}" = "${helper_predicate}" ]
}

@test "when sudo is declined, the printed managed-mcp.json install command names a merged file that still exists" {
    write_host_claude_json '{"mcpServers": {"host-ide": {"type": "sse", "url": "http://localhost:64342/sse"}}}'
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sudo install -o root -g root -m 0444 ${HOME}/.claude/managed-mcp.merged.json ${CLAUDE_MANAGED_DIR}/managed-mcp.json"* ]]
    [[ "${output}" == *"sudo install -o root -g root -m 0755 ${SOURCE_CFWF_MCP_HEADERS} ${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers"* ]]
    [ "$(jq -r '.mcpServers | keys | join(" ")' "${HOME}/.claude/managed-mcp.merged.json")" = "$(expected_mcp_names host-ide)" ]
}

@test "a merged MCP file that cannot be written is fatal before anything is installed" {
    allow_sudo
    mkdir -p "${HOME}/.claude/managed-mcp.merged.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to write ${HOME}/.claude/managed-mcp.merged.json"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

@test "a merged MCP file that is not valid JSON is fatal before anything is installed" {
    allow_sudo
    # Fails only the validation of the merged file; every other jq call is the real one.
    jq() {
        if [ "$1" = "empty" ] && [ "$2" = "${HOME}/.claude/managed-mcp.merged.json" ]; then
            return 1
        fi
        builtin command jq "$@"
    }
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Merged MCP servers are not valid JSON: ${HOME}/.claude/managed-mcp.merged.json"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

# --- the shipped managed MCP servers ------------------------------------------------

@test "the shipped managed-mcp.json holds the required cfwf server, over https with its header from the root-owned helper" {
    run jq -c '.mcpServers.cfwf' "${SOURCE_MANAGED_MCP}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "{\"type\":\"http\",\"url\":\"${CFWF_URL}\",\"headersHelper\":\"/etc/claude-code/mcp/cfwf-mcp-headers\"}" ]
}

# The shipped file may list servers beyond the required ones, so this uses a copy with an extra one
# rather than pinning a real name such as rider.
@test "a host server with an extra shipped server's name and definition is installed once, and with another definition is fatal (#1850)" {
    allow_sudo
    SOURCE_MANAGED_MCP="${TEST_TMP}/shipped-extra.json"
    jq '.mcpServers["shipped-ide"] = {"type": "http", "url": "http://127.0.0.1:65000/stream"}' "${SOURCE_DIR}/claude-managed-mcp.json" > "${SOURCE_MANAGED_MCP}"
    write_host_claude_json '{"mcpServers": {"shipped-ide": {"type": "http", "url": "http://127.0.0.1:65000/stream"}}}'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [[ " $(installed_mcp_names) " == *" shipped-ide "* ]]
    [[ "${output}" != *"Left out"* ]]

    rm -rf "${CLAUDE_MANAGED_DIR}"
    write_host_claude_json '{"mcpServers": {"shipped-ide": {"type": "http", "url": "http://127.0.0.1:65000/stream"}, "ide-alias": {"type": "http", "url": "http://127.0.0.1:65000/stream"}}}'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "$(expected_mcp_names)" ]
    [[ "${output}" == *"Left out ide-alias from ${HOME}/.claude.json: same URL as shipped-ide, which replaces them"* ]]
    [[ "${output}" != *"Left out shipped-ide"* ]]

    rm -rf "${CLAUDE_MANAGED_DIR}"
    write_host_claude_json '{"mcpServers": {"shipped-ide": {"type": "sse", "url": "http://localhost:64342/sse"}}}'
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"used for two different servers"*": shipped-ide."* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
}

@test "the shipped kb server is over https with its header from the root-owned helper, and no headers or env" {
    run jq -c '.mcpServers.kb' "${SOURCE_MANAGED_MCP}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "{\"type\":\"http\",\"url\":\"${KB_URL}\",\"headersHelper\":\"/etc/claude-code/mcp/kb-mcp-headers\"}" ]
}

@test "the shipped build-dotnet server is the stdio server started by the root-owned wrapper, with no env" {
    run jq -c '.mcpServers["build-dotnet"]' "${SOURCE_MANAGED_MCP}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"type":"stdio","command":"/etc/claude-code/mcp/build-dotnet-mcp"}' ]
}

@test "the shipped codegraph server is the stdio codegraph serve --mcp entry codegraph install writes, with no env" {
    run jq -c '.mcpServers.codegraph' "${SOURCE_MANAGED_MCP}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"type":"stdio","command":"codegraph","args":["serve","--mcp"],"alwaysLoad":true}' ]
}

@test "no server in the shipped managed-mcp.json carries literal headers (#1818)" {
    run jq -c '[.mcpServers | to_entries[] | select(.value | has("headers")) | .key]' "${SOURCE_MANAGED_MCP}"
    [ "${output}" = '[]' ]
}

@test "the shipped managed-mcp.json carries no literal Authorization header and no \${VAR} expansion" {
    [ "$(grep -ci 'authorization' "${SOURCE_MANAGED_MCP}")" -eq 0 ]
    # shellcheck disable=SC2016  # the literal ${ that starts a Claude Code expansion
    [ "$(grep -cF '${' "${SOURCE_MANAGED_MCP}")" -eq 0 ]
}

@test "the managed settings allow every cfwf MCP tool" {
    jq -r '.permissions.allow[]' "${SOURCE_MANAGED_SETTINGS}" | grep -qxF 'mcp__cfwf__*'
}

@test "the managed settings allow every kb MCP tool and deny none of them" {
    jq -r '.permissions.allow[]' "${SOURCE_MANAGED_SETTINGS}" | grep -qxF 'mcp__kb__*'
    [ "$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}" | grep -c '^mcp__kb__')" -eq 0 ]
}

@test "the managed settings allow every build-dotnet MCP tool (#1818)" {
    jq -r '.permissions.allow[]' "${SOURCE_MANAGED_SETTINGS}" | grep -qxF 'mcp__build-dotnet__*'
}

@test "the managed settings allow every codegraph MCP tool and deny none of them" {
    jq -r '.permissions.allow[]' "${SOURCE_MANAGED_SETTINGS}" | grep -qxF 'mcp__codegraph__*'
    [ "$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}" | grep -c '^mcp__codegraph__')" -eq 0 ]
}

# Agents reach CodeGraph only through its MCP tools, so the shell has no codegraph entry at all.
@test "the managed settings allow no codegraph shell command" {
    run jq -r '.permissions.allow[] | select(startswith("Bash(codegraph"))' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "the Dockerfile sanity block pins the codegraph allow rule and requires the binary" {
    local dockerfile="${SOURCE_DIR}/Dockerfile"
    grep -qF "jq -e '.permissions.allow | index(\"mcp__codegraph__*\")' /etc/claude-code/managed-settings.json" "${dockerfile}"
    grep -qE '^ +xmllint codegraph; do \\$' "${dockerfile}"
}

@test "the Dockerfile sanity block pins the build-dotnet server, its wrapper's owner and mode, its root, its tool mode, the global tool and allow rule, forbids Authorization text, and pins no server set (#1818, #1850)" {
    local dockerfile="${SOURCE_DIR}/Dockerfile"
    [ "$(grep -cF '.mcpServers | keys' "${dockerfile}")" -eq 0 ]
    grep -qF "! grep -qi 'authorization' /etc/claude-code/managed-mcp.json" "${dockerfile}"
    grep -qF "jq -e '.mcpServers[\"build-dotnet\"] == {\"type\": \"stdio\", \"command\": \"/etc/claude-code/mcp/build-dotnet-mcp\"}' /etc/claude-code/managed-mcp.json" "${dockerfile}"
    grep -qF "[ \"\$(stat -c '%U:%G %a' /etc/claude-code/mcp/build-dotnet-mcp)\" = \"root:root 755\" ]" "${dockerfile}"
    # shellcheck disable=SC2016  # the literal ${...} the sanity block's shell expands
    grep -qF '[ "${BUILD_MCP_REPO_ROOT}" = "/workspace/repo" ]' "${dockerfile}"
    # shellcheck disable=SC2016  # the literal ${...} the sanity block's shell expands
    grep -qF '[ "${BUILD_MCP_TOOL}" = "global" ]' "${dockerfile}"
    grep -qF '[ -x /home/developer/.dotnet/tools/credfeto-build-dotnet ]' "${dockerfile}"
    grep -qF "jq -e '.permissions.allow | index(\"mcp__build-dotnet__*\")' /etc/claude-code/managed-settings.json" "${dockerfile}"
    grep -qE 'for tool in .* credfeto\.build\.dotnet\.server; do' "${dockerfile}"
}

# Prints each jq program the Dockerfile sanity block runs against /etc/claude-code/managed-mcp.json,
# one per line (none of them holds a single quote or a newline).
dockerfile_mcp_programs() {
    grep -oP "jq -e '\K[^']+(?=' /etc/claude-code/managed-mcp\.json)" "${SOURCE_DIR}/Dockerfile"
}

# Runs every one of those programs against the given file; fails when any of them does.
run_dockerfile_mcp_checks() {
    local program
    while IFS= read -r program; do
        jq -e "${program}" "$1" > /dev/null 2>&1 || return 1
    done < <(dockerfile_mcp_programs)
}

@test "the Dockerfile managed-mcp.json checks pass the shipped file and a copy with extra servers (#1850)" {
    [ "$(dockerfile_mcp_programs | wc -l)" -ge 4 ]
    run_dockerfile_mcp_checks "${SOURCE_MANAGED_MCP}"

    jq '.mcpServers += {"extra-ide": {"type": "http", "url": "http://127.0.0.1:65000/stream"}, "extra-tool": {"type": "stdio", "command": "/usr/bin/extra-tool", "env": {"MODE": "serve"}}}' "${SOURCE_MANAGED_MCP}" > "${TEST_TMP}/extra.json"
    run_dockerfile_mcp_checks "${TEST_TMP}/extra.json"
}

@test "the Dockerfile managed-mcp.json checks fail without cfwf, kb, build-dotnet or codegraph, or with any of them changed (#1850)" {
    local filter
    for filter in \
        'del(.mcpServers.cfwf)' \
        '.mcpServers.cfwf.url = "https://elsewhere.example.com/mcp"' \
        'del(.mcpServers.cfwf.headersHelper)' \
        '.mcpServers.cfwf.headers = {"X-Key": "literal"}' \
        'del(.mcpServers.kb)' \
        '.mcpServers.kb.url = "https://kb.example.com/mcp"' \
        'del(.mcpServers.kb.headersHelper)' \
        '.mcpServers.kb.headers = {"X-Key": "literal"}' \
        '.mcpServers.kb = {"type": "stdio", "command": "/usr/bin/kb"}' \
        'del(.mcpServers["build-dotnet"])' \
        '.mcpServers["build-dotnet"].env.EXTRA = "x"' \
        '.mcpServers["build-dotnet"].command = "/home/developer/.dotnet/tools/credfeto-build-dotnet"' \
        'del(.mcpServers.codegraph)' \
        '.mcpServers.codegraph.type = "http"' \
        '.mcpServers.codegraph.command = "/usr/bin/other-codegraph"' \
        '.mcpServers.codegraph.args = ["serve"]' \
        '.mcpServers.codegraph.env = {"CODEGRAPH_TELEMETRY": "1"}' \
        'del(.mcpServers.codegraph.alwaysLoad)'; do
        jq "${filter}" "${SOURCE_MANAGED_MCP}" > "${TEST_TMP}/broken.json"
        if run_dockerfile_mcp_checks "${TEST_TMP}/broken.json"; then
            echo "the Dockerfile checks accepted: ${filter}" >&2
            return 1
        fi
    done
}

@test "development-credfeto-tools installs Credfeto.Build.Dotnet.Server behind the cache bust and its sanity check requires it (#1818)" {
    local dockerfile="${REPO_ROOT}/containers/base/development-credfeto-tools/Dockerfile"
    # shellcheck disable=SC2016  # the literal ${...} of the Dockerfile's ARG substitution
    grep -qxF 'RUN su developer -c ": ${CREDFETO_FUNFAIR_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.Build.Dotnet.Server"' "${dockerfile}"
    # Both the installed-versions report and the sanity check list the package.
    [ "$(grep -cE 'for tool in .* credfeto\.build\.dotnet\.server; do' "${dockerfile}")" -eq 2 ]
    grep -qF '[ -x /home/developer/.dotnet/tools/credfeto-build-dotnet ]' "${dockerfile}"
    grep -qF 'su developer -c "command -v credfeto-build-dotnet >/dev/null 2>&1"' "${dockerfile}"
    # The cache bust hashes the package's latest version, so a new release rebuilds the layer.
    grep -qxF '            Credfeto.Build.Dotnet.Server' "${REPO_ROOT}/.github/workflows/build-development-credfeto-tools.yml"
    grep -qxF '            Credfeto.Build.Dotnet.Server' "${REPO_ROOT}/.github/workflows/check-credfeto-tools-updates.yml"
}

@test "the Dockerfile sanity block pins the cfwf server, its helper's owner and mode, and its allow rule" {
    local dockerfile="${SOURCE_DIR}/Dockerfile"
    grep -qF "jq -e '.mcpServers.cfwf == {\"type\": \"http\", \"url\": \"${CFWF_URL}\", \"headersHelper\": \"/etc/claude-code/mcp/cfwf-mcp-headers\"}' /etc/claude-code/managed-mcp.json" "${dockerfile}"
    grep -qF "[ \"\$(stat -c '%U:%G %a' /etc/claude-code/mcp/cfwf-mcp-headers)\" = \"root:root 755\" ]" "${dockerfile}"
    grep -qF "jq -e '.permissions.allow | index(\"mcp__cfwf__*\")' /etc/claude-code/managed-settings.json" "${dockerfile}"
}

@test "the Dockerfile sanity block pins the kb server, its helper's owner and mode, and its allow rule" {
    local dockerfile="${SOURCE_DIR}/Dockerfile"
    grep -qF "jq -e '.mcpServers.kb == {\"type\": \"http\", \"url\": \"${KB_URL}\", \"headersHelper\": \"/etc/claude-code/mcp/kb-mcp-headers\"}' /etc/claude-code/managed-mcp.json" "${dockerfile}"
    grep -qF "[ \"\$(stat -c '%U:%G %a' /etc/claude-code/mcp/kb-mcp-headers)\" = \"root:root 755\" ]" "${dockerfile}"
    grep -qF "jq -e '.permissions.allow | index(\"mcp__kb__*\")' /etc/claude-code/managed-settings.json" "${dockerfile}"
}

@test "the Dockerfile sanity block fails the build unless raw gh is denied by both layers and cfwf stays allowed (#1805)" {
    local dockerfile="${SOURCE_DIR}/Dockerfile"
    grep -qF 'jq -e '"'"'(.permissions.deny | index("Bash(gh)") and index("Bash(gh *)")) and (.permissions.allow | index("Bash(cfwf *)"))' "${dockerfile}"
    grep -qF 'cut -f1 /etc/claude-code/hooks/command-blocklist | grep -qxF gh' "${dockerfile}"
    grep -qF "! grep -qE '^[[:space:]]*gh[[:space:]]' /etc/claude-code/hooks/command-allowlist" "${dockerfile}"
    # gh itself stays installed: cfwf runs it as its own subprocess.
    grep -qE 'for cmd in git gh ' "${dockerfile}"
}

@test "the Dockerfile copies managed-mcp.json, the headers helpers and the build-dotnet wrapper into /etc/claude-code, and sets the wrapper's root and tool mode" {
    local dockerfile="${SOURCE_DIR}/Dockerfile"
    grep -qxF 'COPY --chown=root:root --chmod=0444 claude-managed-mcp.json /etc/claude-code/managed-mcp.json' "${dockerfile}"
    grep -qxF 'COPY --chown=root:root --chmod=0755 claude-mcp/cfwf-mcp-headers /etc/claude-code/mcp/cfwf-mcp-headers' "${dockerfile}"
    grep -qxF 'COPY --chown=root:root --chmod=0755 claude-mcp/kb-mcp-headers /etc/claude-code/mcp/kb-mcp-headers' "${dockerfile}"
    grep -qxF 'COPY --chown=root:root --chmod=0755 claude-mcp/build-dotnet-mcp /etc/claude-code/mcp/build-dotnet-mcp' "${dockerfile}"
    grep -qxF 'ENV BUILD_MCP_REPO_ROOT=/workspace/repo' "${dockerfile}"
    grep -qxF 'ENV BUILD_MCP_TOOL=global' "${dockerfile}"
    [ -x "${SOURCE_CFWF_MCP_HEADERS}" ]
    [ -x "${SOURCE_KB_MCP_HEADERS}" ]
    [ -x "${SOURCE_BUILD_DOTNET_MCP}" ]
}

# --- legacy ~/.claude/hooks symlinks -------------------------------------------

@test "stale ~/.claude/hooks symlinks into the checkout are removed, anything else there is kept" {
    allow_sudo
    mkdir -p "${HOME}/.claude/hooks" "${TEST_TMP}/elsewhere"
    ln -s "${SOURCE_HOOKS_DIR}/enforce-git-policy" "${HOME}/.claude/hooks/enforce-git-policy"
    ln -s "${SOURCE_HOOKS_DIR}/allowed-dirs" "${HOME}/.claude/hooks/allowed-dirs"
    printf '%s\n' "${HOME}/work" > "${HOME}/.claude/hooks/allowed-dirs.local"
    printf 'x' > "${TEST_TMP}/elsewhere/mine"
    ln -s "${TEST_TMP}/elsewhere/mine" "${HOME}/.claude/hooks/mine"

    run main
    [ "${status}" -eq 0 ]
    [ ! -e "${HOME}/.claude/hooks/enforce-git-policy" ]
    [ ! -L "${HOME}/.claude/hooks/allowed-dirs" ]
    [ -f "${HOME}/.claude/hooks/allowed-dirs.local" ]
    [ -L "${HOME}/.claude/hooks/mine" ]
    [[ "${output}" == *"Removed stale symlink ${HOME}/.claude/hooks/enforce-git-policy"* ]]
}

# --- allowed-dirs.local --------------------------------------------------------

# Every file the install wrote, with its mode and checksum, and every root command it asked sudo
# for, so two runs can be compared for an identical install.
install_snapshot() {
    (cd "${TEST_TMP}" && find etc home bin -printf '%y %m %P\n' | sort)
    (cd "${TEST_TMP}" && find etc home bin -type f -exec sha256sum {} + | sort)
    cat "${SUDO_LOG}"
}

reset_install() {
    rm -rf "${CLAUDE_MANAGED_DIR}" "${HOME}/.claude" "${SUDO_LOG}"
    rm -f "${CFWF_BIN_DIR}"/*
}

@test "install-claude-hooks ignores every argument and does the same full install as with none" {
    allow_sudo
    local baseline args
    run "${REPO_ROOT}/install-claude-hooks"
    [ "${status}" -eq 0 ]
    baseline=$(install_snapshot)
    [ -f "${CLAUDE_MANAGED_DIR}/managed-settings.json" ]

    for args in '--system' 'hello world' '--help'; do
        reset_install
        # shellcheck disable=SC2086  # split on purpose: each word is a separate argument
        run "${REPO_ROOT}/install-claude-hooks" ${args}
        [ "${status}" -eq 0 ]
        [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local" ]
        [ "$(install_snapshot)" = "${baseline}" ]
    done
}

@test "a readable file named as an argument is never installed as allowed-dirs.local" {
    allow_sudo
    printf '%s\n' "${HOME}/work" > "${TEST_TMP}/my-dirs"
    run "${REPO_ROOT}/install-claude-hooks" "${TEST_TMP}/my-dirs"
    [ "${status}" -eq 0 ]
    [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local" ]
    run grep -c 'allowed-dirs.local' "${SUDO_LOG}"
    [ "${output}" = "0" ]
}

@test "with no allowed-dirs.local installed, main warns to create one by hand rather than fabricating one" {
    allow_sudo
    run main
    [ "${status}" -eq 0 ]
    [ ! -e "${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local" ]
    [[ "${output}" == *"No ${CLAUDE_MANAGED_DIR}/hooks/allowed-dirs.local found"* ]]
    [[ "${output}" == *"Create it by hand, root-owned with mode 0444, with one allowed root per line"* ]]
    [[ "${output}" != *'<file>'* ]]
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
    diff "${SOURCE_HOOKS_DIR}/enforce-git-policy" "${CLAUDE_MANAGED_DIR}/hooks/enforce-git-policy"
}

# --- the shipped managed settings ------------------------------------------------

@test "the managed settings lock out every other settings source and disable bypass mode" {
    run jq -r '[.allowManagedPermissionRulesOnly, .allowManagedHooksOnly, .allowManagedMcpServersOnly, .permissions.disableBypassPermissionsMode, .permissions.defaultMode] | map(tostring) | join(" ")' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "true true true disable dontAsk" ]
}

@test "every managed hook command is an absolute /etc/claude-code/hooks path" {
    local cmd count=0
    while IFS= read -r cmd; do
        count=$((count + 1))
        [[ "${cmd}" == /etc/claude-code/hooks/* ]] || { echo "not an /etc/claude-code/hooks path: ${cmd}" >&2; return 1; }
    done < <(jq -r '.hooks[][].hooks[].command' "${SOURCE_MANAGED_SETTINGS}")
    [ "${count}" -gt 0 ]
}

@test "no managed hook command is a bare command looked up on PATH" {
    run jq -r '[.hooks[][].hooks[].command | select(startswith("/") | not)] | join(" ")' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "the managed settings do not wire in the npm block-no-verify tool" {
    run grep -q 'block-no-verify' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 1 ]
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

@test "the Bash chain runs enforce-allowed-dirs straight after reject-obfuscated-commands" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0:2][] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/etc/claude-code/hooks/reject-obfuscated-commands
/etc/claude-code/hooks/enforce-allowed-dirs" ]
}

@test "the Bash chain includes block-git-worktree, block-dotnet-tool-install and cache-gh-lookups" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'/etc/claude-code/hooks/block-git-worktree'* ]]
    [[ "${output}" == *'/etc/claude-code/hooks/block-dotnet-tool-install'* ]]
    [[ "${output}" == *'/etc/claude-code/hooks/cache-gh-lookups'* ]]
}

@test "block-git-worktree is registered against the native EnterWorktree tool" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "EnterWorktree") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/block-git-worktree' ]
}

@test "block-github-mcp-write-tools is registered against the mcp__github__.* matcher" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "mcp__github__.*") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/block-github-mcp-write-tools' ]
}

@test "enforce-allowed-dirs and block-secret-file-reads are registered against the Edit, Write and NotebookEdit tools" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|NotebookEdit") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/enforce-allowed-dirs
/etc/claude-code/hooks/block-secret-file-reads' ]
}

@test "block-secret-file-reads is registered against the Bash chain and the Read tool" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'/etc/claude-code/hooks/block-secret-file-reads'* ]]
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[] | .command' "${SOURCE_MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/block-secret-file-reads' ]
}

@test "the repo's own .claude settings, .mcp.json and ~/.claude.json are denied to Edit by relative path" {
    local denies entry
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}")
    for entry in 'Edit(.claude/settings*.json*)' 'Edit(.mcp.json)' 'Edit(~/.claude.json)'; do
        printf '%s\n' "${denies}" | grep -qxF "${entry}" || { echo "missing deny ${entry}" >&2; return 1; }
    done
}

@test "the user's and any project's .claude skills, agents, commands, plugins, rules, output-styles, sessions, CLAUDE.md, .credentials.json and history.jsonl are denied to Edit" {
    local denies dir file prefix entry
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}")
    for prefix in '~' '*'; do
        for dir in skills agents commands plugins rules output-styles sessions; do
            entry="Edit(${prefix}/.claude/${dir}/**)"
            printf '%s\n' "${denies}" | grep -qxF "${entry}" || { echo "missing deny ${entry}" >&2; return 1; }
        done
        for file in CLAUDE.md .credentials.json history.jsonl; do
            entry="Edit(${prefix}/.claude/${file})"
            printf '%s\n' "${denies}" | grep -qxF "${entry}" || { echo "missing deny ${entry}" >&2; return 1; }
        done
    done
}

@test "the user's git, gh and curl configuration and gh's extension directory are denied to Edit" {
    local denies entry
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}")
    for entry in 'Edit(~/.curlrc)' 'Edit(~/.config/curlrc)' 'Edit(~/.gitconfig)' 'Edit(~/.config/git/**)' 'Edit(~/.config/gh/**)' 'Edit(~/.local/share/gh/**)'; do
        printf '%s\n' "${denies}" | grep -qxF "${entry}" || { echo "missing deny ${entry}" >&2; return 1; }
    done
}

@test "any repository's git config and hooks are denied to Edit, by relative path and at any depth" {
    local denies prefix path entry
    denies=$(jq -r '.permissions.deny[]' "${SOURCE_MANAGED_SETTINGS}")
    for prefix in '' '*/'; do
        entry="Edit(${prefix}.git)"
        printf '%s\n' "${denies}" | grep -qxF "${entry}" || { echo "missing deny ${entry}" >&2; return 1; }
        for path in config config.worktree commondir 'hooks/**' 'modules/**' 'worktrees/**'; do
            entry="Edit(${prefix}.git/${path})"
            printf '%s\n' "${denies}" | grep -qxF "${entry}" || { echo "missing deny ${entry}" >&2; return 1; }
        done
    done
}

@test "every code-execution/destructive flag is denied in both the first and a later argument position" {
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
    for exact in "Bash(rm -rf /)" "Bash(rm -fr /)" "Bash(rm -r -f /)" "Bash(rm -f -r /)" "Bash(rm * /)"; do
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
    # enforce-allowed-dirs resolves the script path, so a text deny on `..` would only block
    # legitimate names such as build..min.js.
    for exact in "Bash(node *..*)" "Bash(node ..*)"; do
        if printf '%s\n' "${denies}" | grep -qxF "${exact}"; then
            echo "unexpected deny ${exact} - enforce-allowed-dirs checks the resolved script path" >&2
            return 1
        fi
    done
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

@test "dies before installing anything when the user settings are not valid JSON" {
    allow_sudo
    printf '{ not json' > "${TEST_TMP}/broken.json"
    SOURCE_USER_SETTINGS="${TEST_TMP}/broken.json"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"User settings are not valid JSON"* ]]
    [ ! -e "${CLAUDE_MANAGED_DIR}" ]
    [ ! -e "${HOME}/.claude/settings.json" ]
    [ ! -e "${CFWF_BIN_DIR}/cfwf" ]
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
    run grep -cF "${CFWF_BIN_DIR}/cfwf" "${SUDO_LOG}"
    [ "${output}" = "0" ]
}

@test "when sudo is declined, main prints the cfwf sudo command to run and still installs the user settings" {
    CFWF_BIN_DIR="${TEST_TMP}/no/such/dir"
    run main
    [ "${status}" -eq 0 ]
    [ -f "${SUDO_LOG}" ]
    [[ "${output}" == *"Could not install cfwf to ${CFWF_BIN_DIR}/cfwf"* ]]
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
