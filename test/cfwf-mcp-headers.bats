#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper

HELPER="${REPO_ROOT}/containers/base/development-full/claude-mcp/cfwf-mcp-headers"

setup() {
    setup_isolated_env
    # The helper runs with PATH set to the stub directory alone, so no real gh on this host can
    # answer; jq, plus env and bash for the stubs' shebang, are linked in beside the stubs.
    local tool
    for tool in jq env bash; do
        ln -s "$(which "${tool}")" "${STUB_BIN}/${tool}"
    done
}

teardown() {
    cleanup_stubs
}

# Runs the helper with only the given NAME=value variables (env -i drops every token the host
# exported), stdout in output and stderr in stderr.
run_helper() {
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${HOME}" "$@" "${HELPER}"
}

# A gh stub that logs its arguments and prints the given token for `gh auth token`.
stub_gh_token() {
    export GH_LOG="${TEST_TMP}/gh.log"
    make_stub gh "printf '%s\n' \"\$*\" >> '${GH_LOG}'; [ \"\$1 \$2\" = 'auth token' ] && printf '%s\n' '$1'"
}

@test "GH_ENTERPRISE_TOKEN is used ahead of GH_TOKEN and gh" {
    stub_gh_token gho_from_gh
    run_helper GH_ENTERPRISE_TOKEN=ghp_enterprise GH_TOKEN=ghp_direct
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer ghp_enterprise"}' ]
    [ ! -e "${GH_LOG}" ]
}

@test "GH_TOKEN is used when GH_ENTERPRISE_TOKEN is unset or empty, ahead of gh" {
    stub_gh_token gho_from_gh
    run_helper GH_TOKEN=ghp_direct
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer ghp_direct"}' ]

    run_helper GH_ENTERPRISE_TOKEN= GH_TOKEN=ghp_direct
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer ghp_direct"}' ]
    [ ! -e "${GH_LOG}" ]
}

@test "with neither variable set, gh auth token is asked for GH_HOST" {
    stub_gh_token gho_from_gh
    run_helper GH_HOST=github-api.example.com
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer gho_from_gh"}' ]
    [ "$(cat "${GH_LOG}")" = 'auth token --hostname github-api.example.com' ]
}

@test "with neither variable nor GH_HOST set, gh auth token is asked for gh's default host" {
    stub_gh_token gho_from_gh
    run_helper
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer gho_from_gh"}' ]
    [ "$(cat "${GH_LOG}")" = 'auth token' ]
}

@test "the output is one JSON object holding only an Authorization header" {
    run_helper GH_TOKEN=ghp_direct
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | wc -l)" -eq 1 ]
    run jq -r 'keys | join(" ")' <<<"${output}"
    [ "${output}" = 'Authorization' ]
}

@test "no token anywhere exits non-zero with nothing on stdout" {
    make_stub gh 'exit 1'
    run_helper
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'no GitHub token'* ]]
}

@test "no token and no gh installed exits non-zero with nothing on stdout" {
    run_helper GH_HOST=github.com
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'no GitHub token'* ]]
}

@test "gh printing nothing counts as no token" {
    make_stub gh 'exit 0'
    run_helper
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "the token never reaches stderr, including from gh's own error output" {
    make_stub gh "printf '%s\n' 'gho_leaked_by_gh' >&2; exit 1"
    run_helper
    [ "${status}" -eq 1 ]
    [[ "${stderr}" != *'gho_leaked_by_gh'* ]]

    run_helper GH_TOKEN=ghp_direct
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
}

@test "a token holding characters a bearer token cannot contain is refused and not echoed" {
    local bad
    for bad in 'ghp_a b' 'ghp_a"b' 'ghp_a\b' $'ghp_a\nX-Other: 1' 'ghp_a;b'; do
        run_helper "GH_TOKEN=${bad}"
        [ "${status}" -eq 1 ] || { echo "accepted ${bad}" >&2; return 1; }
        [ -z "${output}" ] || { echo "printed output for ${bad}: ${output}" >&2; return 1; }
        [[ "${stderr}" != *'ghp_a'* ]] ||{ echo "echoed ${bad} to stderr" >&2; return 1; }
    done
}

@test "every token68 character is accepted" {
    run_helper 'GH_TOKEN=Az09-._~+/='
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"Authorization":"Bearer Az09-._~+/="}' ]
}

@test "a jq failure exits non-zero with nothing on stdout and no token on stderr" {
    make_stub jq 'exit 1'
    run_helper GH_TOKEN=ghp_direct_secret
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *'jq could not build the Authorization header'* ]]
    [[ "${stderr}" != *'ghp_direct_secret'* ]]
}
