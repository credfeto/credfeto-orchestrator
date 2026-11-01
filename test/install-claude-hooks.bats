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

    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/hooks/enforce-git-dash-c")" = "755" ]
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

# --- managed MCP servers: cfwf merged with the host's ~/.claude.json -----------

CFWF_URL='https://workflow-mcp.markridgwell.com/mcp'

# Writes the given JSON as the host's ~/.claude.json.
write_host_claude_json() {
    printf '%s\n' "$1" > "${HOME}/.claude.json"
}

installed_mcp_names() {
    jq -r '.mcpServers | keys | join(" ")' "${CLAUDE_MANAGED_DIR}/managed-mcp.json"
}

@test "the headers helper and managed-mcp.json are installed via sudo, 0755 and 0444" {
    allow_sudo
    main

    diff "${SOURCE_MCP_HEADERS}" "${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers"
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers")" = "755" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "444" ]
    [ "$(stat -c '%a' "${CLAUDE_MANAGED_DIR}/mcp")" = "755" ]
    grep -qxF "install -o root -g root -m 0755 ${SOURCE_MCP_HEADERS} ${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers" "${SUDO_LOG}"
    grep -qxF "install -o root -g root -m 0444 ${HOME}/.claude/managed-mcp.merged.json ${CLAUDE_MANAGED_DIR}/managed-mcp.json" "${SUDO_LOG}"
}

@test "with no ~/.claude.json, managed-mcp.json holds the shipped cfwf server alone" {
    allow_sudo
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "cfwf" ]
    [ "$(jq -S . "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -S . "${SOURCE_MANAGED_MCP}")" ]
    [[ "${output}" == *"re-run this script after adding an MCP server there"* ]]
}

@test "an empty ~/.claude.json, or one with no MCP servers, installs cfwf alone" {
    allow_sudo
    : > "${HOME}/.claude.json"
    main
    [ "$(installed_mcp_names)" = "cfwf" ]

    write_host_claude_json '{"projects": {"/x": {"allowedTools": []}}, "theme": "dark"}'
    main
    [ "$(installed_mcp_names)" = "cfwf" ]
}

@test "user-scope and every project's MCP servers are merged in beside cfwf" {
    allow_sudo
    write_host_claude_json '{
        "mcpServers": {"rider": {"type": "sse", "url": "http://localhost:64342/sse"}},
        "projects": {
            "/a": {"mcpServers": {"tool-a": {"type": "stdio", "command": "/usr/bin/tool-a", "args": ["--serve"]}}},
            "/b": {"mcpServers": {"tool-b": {"type": "http", "url": "https://b.example.com/mcp"}}}
        }
    }'
    main

    [ "$(installed_mcp_names)" = "cfwf rider tool-a tool-b" ]
    [ "$(jq -r '.mcpServers["tool-a"].args[0]' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "--serve" ]
    [ "$(jq -c '.mcpServers.cfwf' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = "$(jq -c '.mcpServers.cfwf' "${SOURCE_MANAGED_MCP}")" ]
}

@test "a host server at cfwf's URL is left out as a duplicate, and its removal is suggested" {
    allow_sudo
    write_host_claude_json "{\"projects\": {\"${HOME}\": {\"mcpServers\": {\"secure-api\": {\"type\": \"http\", \"url\": \"${CFWF_URL}/\", \"headers\": {\"Authorization\": \"Bearer ghp_hostsecret\"}}}}}}"
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "cfwf" ]
    [[ "${output}" == *"Left out secure-api from ${HOME}/.claude.json: same URL as cfwf"* ]]
    [[ "${output}" == *"Remove them from ${HOME}/.claude.json"* ]]
    [ "$(grep -c 'ghp_hostsecret' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" -eq 0 ]
    [[ "${output}" != *'ghp_hostsecret'* ]]
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
    [ "$(installed_mcp_names)" = "cfwf" ]
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
    [ "$(installed_mcp_names)" = "by-ref cfwf" ]
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
    [ "$(installed_mcp_names)" = "cfwf" ]
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
    [ "$(installed_mcp_names)" = "cfwf" ]
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
    [ "$(installed_mcp_names)" = "cfwf clean-args clean-url ref-args" ]
    # shellcheck disable=SC2016
    [ "$(jq -r '.mcpServers["ref-args"].args[1]' "${CLAUDE_MANAGED_DIR}/managed-mcp.json")" = '${S_TOKEN}' ]
    [[ "${output}" != *'did not copy'* ]]
}

@test "a ~/.claude.json bigger than the kernel's per-argument limit is still merged" {
    allow_sudo
    local padding
    padding=$(head -c 200000 /dev/zero | tr '\0' 'x')
    write_host_claude_json "{\"padding\": \"${padding}\", \"mcpServers\": {\"rider\": {\"type\": \"sse\", \"url\": \"http://localhost:64342/sse\"}}}"
    [ "$(stat -c '%s' "${HOME}/.claude.json")" -gt 131072 ]
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "cfwf rider" ]
}

@test "the same server repeated in several scopes is installed once" {
    allow_sudo
    write_host_claude_json '{
        "mcpServers": {"rider": {"type": "sse", "url": "http://localhost:64342/sse"}},
        "projects": {"/a": {"mcpServers": {"rider": {"type": "sse", "url": "http://localhost:64342/sse"}}}}
    }'
    run main
    [ "${status}" -eq 0 ]
    [ "$(installed_mcp_names)" = "cfwf rider" ]
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
    SOURCE_MCP_HEADERS="${TEST_TMP}/does-not-exist"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Source MCP headers helper not found"* ]]
}

@test "when sudo is declined, the printed managed-mcp.json install command names a merged file that still exists" {
    write_host_claude_json '{"mcpServers": {"rider": {"type": "sse", "url": "http://localhost:64342/sse"}}}'
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sudo install -o root -g root -m 0444 ${HOME}/.claude/managed-mcp.merged.json ${CLAUDE_MANAGED_DIR}/managed-mcp.json"* ]]
    [[ "${output}" == *"sudo install -o root -g root -m 0755 ${SOURCE_MCP_HEADERS} ${CLAUDE_MANAGED_DIR}/mcp/cfwf-mcp-headers"* ]]
    [ "$(jq -r '.mcpServers | keys | join(" ")' "${HOME}/.claude/managed-mcp.merged.json")" = "cfwf rider" ]
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

@test "the shipped managed-mcp.json holds only cfwf, over https, with its header from the root-owned helper" {
    run jq -c '.' "${SOURCE_MANAGED_MCP}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "{\"mcpServers\":{\"cfwf\":{\"type\":\"http\",\"url\":\"${CFWF_URL}\",\"headersHelper\":\"/etc/claude-code/mcp/cfwf-mcp-headers\"}}}" ]
}

@test "the shipped managed-mcp.json carries no literal Authorization header and no \${VAR} expansion" {
    [ "$(grep -ci 'authorization' "${SOURCE_MANAGED_MCP}")" -eq 0 ]
    # shellcheck disable=SC2016  # the literal ${ that starts a Claude Code expansion
    [ "$(grep -cF '${' "${SOURCE_MANAGED_MCP}")" -eq 0 ]
}

@test "the managed settings allow every cfwf MCP tool" {
    jq -r '.permissions.allow[]' "${SOURCE_MANAGED_SETTINGS}" | grep -qxF 'mcp__cfwf__*'
}

@test "the Dockerfile copies managed-mcp.json and the headers helper into /etc/claude-code" {
    local dockerfile="${SOURCE_DIR}/Dockerfile"
    grep -qxF 'COPY --chown=root:root --chmod=0444 claude-managed-mcp.json /etc/claude-code/managed-mcp.json' "${dockerfile}"
    grep -qxF 'COPY --chown=root:root --chmod=0755 claude-mcp/cfwf-mcp-headers /etc/claude-code/mcp/cfwf-mcp-headers' "${dockerfile}"
    [ -x "${SOURCE_MCP_HEADERS}" ]
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
