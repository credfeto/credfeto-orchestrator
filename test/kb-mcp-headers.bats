#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper

HELPER="${REPO_ROOT}/containers/base/development-full/claude-mcp/kb-mcp-headers"

setup() {
    setup_isolated_env
    # The helper runs with PATH set to the stub directory alone; jq, the find and id it checks
    # the token file with, plus env and bash for the stubs' shebang, are linked in beside the stubs.
    local tool
    for tool in jq find id env bash; do
        ln -s "$(which "${tool}")" "${STUB_BIN}/${tool}"
    done
    TOKEN_FILE="${XDG_CONFIG_HOME}/kb-mcp/token"
}

teardown() {
    cleanup_stubs
}

# Runs the helper with only the given NAME=value variables (env -i drops every token the host
# exported), stdout in output and stderr in stderr.
run_helper() {
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${HOME}" "XDG_CONFIG_HOME=${XDG_CONFIG_HOME}" "$@" "${HELPER}"
}

# Writes the given content to the token file with the given mode.
write_token_file() {
    mkdir -p "${TOKEN_FILE%/*}"
    rm -f "${TOKEN_FILE}"
    printf '%s' "$1" > "${TOKEN_FILE}"
    chmod "$2" "${TOKEN_FILE}"
}

@test "KB_MCP_TOKEN is used ahead of the token file" {
    write_token_file $'kb_from_file\n' 600
    run_helper KB_MCP_TOKEN=kb_from_env
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer kb_from_env"}' ]
}

@test "the token file is used when KB_MCP_TOKEN is unset or empty" {
    write_token_file $'kb_from_file\n' 600
    run_helper
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer kb_from_file"}' ]

    run_helper KB_MCP_TOKEN=
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer kb_from_file"}' ]
}

@test "the token file is found under HOME/.config when XDG_CONFIG_HOME is unset" {
    mkdir -p "${HOME}/.config/kb-mcp"
    printf 'kb_from_home\n' > "${HOME}/.config/kb-mcp/token"
    chmod 600 "${HOME}/.config/kb-mcp/token"
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${HOME}" "${HELPER}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer kb_from_home"}' ]
}

@test "a token file without a trailing newline is read" {
    write_token_file 'kb_no_newline' 600
    run_helper
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer kb_no_newline"}' ]
}

@test "a token file that is not mode 0600 is refused and not read" {
    local mode
    for mode in 644 640 604 400 700; do
        write_token_file $'kb_from_file\n' "${mode}"
        run_helper
        [ "${status}" -eq 1 ] || { echo "accepted mode ${mode}" >&2; return 1; }
        [ -z "${output}" ] || { echo "printed output for mode ${mode}: ${output}" >&2; return 1; }
        [[ "${stderr}" == *'must be a regular file owned by you with mode 0600'* ]]
        [[ "${stderr}" != *'kb_from_file'* ]]
    done
}

@test "a token file not owned by the current user is refused" {
    write_token_file $'kb_from_file\n' 600
    # An id stub reporting another uid stands in for a file owned by someone else.
    local other_uid
    other_uid=$(( $(id -u) + 1 ))
    make_stub id "printf '%s\n' '${other_uid}'"
    run_helper
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'must be a regular file owned by you with mode 0600'* ]]
}

@test "a token file that is a symlink is refused, even to a private file" {
    mkdir -p "${TOKEN_FILE%/*}"
    printf 'kb_from_target\n' > "${TEST_TMP}/target"
    chmod 600 "${TEST_TMP}/target"
    ln -s "${TEST_TMP}/target" "${TOKEN_FILE}"
    run_helper
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'must be a regular file owned by you with mode 0600'* ]]
}

@test "the output is one JSON object holding only an Authorization header" {
    run_helper KB_MCP_TOKEN=kb_direct
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | wc -l)" -eq 1 ]
    run jq -r 'keys | join(" ")' <<<"${output}"
    [ "${output}" = 'Authorization' ]
}

@test "no token anywhere exits non-zero with nothing on stdout" {
    run_helper
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'no kb token: set KB_MCP_TOKEN, or put it in '"${TOKEN_FILE}"' (mode 0600)'* ]]
}

@test "an empty token file counts as no token" {
    write_token_file '' 600
    run_helper
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'no kb token'* ]]
}

@test "the token never reaches stderr" {
    run_helper KB_MCP_TOKEN=kb_direct
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]

    write_token_file $'kb_from_file\n' 600
    run_helper
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
}

@test "a token holding characters a bearer token cannot contain is refused and not echoed" {
    local bad
    for bad in 'kb_a b' 'kb_a"b' 'kb_a\b' $'kb_a\nX-Other: 1' 'kb_a;b'; do
        run_helper "KB_MCP_TOKEN=${bad}"
        [ "${status}" -eq 1 ] || { echo "accepted ${bad}" >&2; return 1; }
        [ -z "${output}" ] || { echo "printed output for ${bad}: ${output}" >&2; return 1; }
        [[ "${stderr}" != *'kb_a'* ]] || { echo "echoed ${bad} to stderr" >&2; return 1; }
    done
}

@test "a token file line holding characters a bearer token cannot contain is refused and not echoed" {
    write_token_file $'kb_a b\n' 600
    run_helper
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'characters a bearer token cannot contain'* ]]
    [[ "${stderr}" != *'kb_a'* ]]
}

@test "every token68 character is accepted" {
    run_helper 'KB_MCP_TOKEN=Az09-._~+/='
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer Az09-._~+/="}' ]
}

@test "the token reaches jq on stdin, never on its command line" {
    local real_jq jq_log="${TEST_TMP}/jq.log"
    # setup linked jq into the stub directory; resolve it so the stub execs the real binary.
    real_jq="$(readlink -f "${STUB_BIN}/jq")"
    make_stub jq "printf '%s\n' \"\$*\" >> '${jq_log}'; exec '${real_jq}' \"\$@\""
    run_helper KB_MCP_TOKEN=kb_direct_secret
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer kb_direct_secret"}' ]
    [ -s "${jq_log}" ]
    run grep -c 'kb_direct_secret' "${jq_log}"
    [ "${output}" = '0' ]
}

@test "a jq failure exits non-zero with nothing on stdout and no token on stderr" {
    make_stub jq 'exit 1'
    run_helper KB_MCP_TOKEN=kb_direct_secret
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'jq could not build the Authorization header'* ]]
    [[ "${stderr}" != *'kb_direct_secret'* ]]
}
