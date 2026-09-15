#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

# shellcheck disable=SC2034  # read by run_hook in test_helper.bash, not visible to shellcheck across `load`
HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-curl-host"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# --- denied hosts, various argument shapes --------------------------------

@test "curl to api.github.com is blocked" {
    run_hook "curl -s https://api.github.com/repos/foo/bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.github.com' is not permitted"* ]]
}

@test "curl to github.com is blocked" {
    run_hook "curl https://github.com/foo/bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'github.com' is not permitted"* ]]
}

@test "curl to registry.npmjs.org is blocked" {
    run_hook "curl https://registry.npmjs.org/foo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'registry.npmjs.org' is not permitted"* ]]
}

@test "curl to raw.githubusercontent.com is blocked" {
    run_hook "curl https://raw.githubusercontent.com/foo/bar/main/x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'raw.githubusercontent.com' is not permitted"* ]]
}

@test "curl to api.nuget.org is blocked" {
    run_hook "curl https://api.nuget.org/v3/index.json"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.nuget.org' is not permitted"* ]]
}

@test "curl to a denied host with no scheme (bare host/path) is blocked" {
    run_hook "curl api.github.com/repos/foo/bar"
    [ "${status}" -eq 2 ]
}

@test "curl --url pointing at a denied host is blocked" {
    run_hook "curl --url https://api.github.com/repos/foo/bar"
    [ "${status}" -eq 2 ]
}

@test "curl to a denied host with userinfo and a port is still matched" {
    run_hook "curl https://user:pass@api.github.com:443/repos/foo"
    [ "${status}" -eq 2 ]
}

@test "curl to a denied host is blocked case-insensitively" {
    run_hook "curl https://API.GITHUB.COM/repos/foo/bar"
    [ "${status}" -eq 2 ]
}

@test "curl to a denied host via a wrapper command is still blocked" {
    run_hook "sudo curl https://github.com/foo"
    [ "${status}" -eq 2 ]
}

# --- allowed hosts and non-URL arguments -----------------------------------

@test "curl to a non-denied host is allowed" {
    run_hook "curl -s https://example.com/foo"
    [ "${status}" -eq 0 ]
}

@test "curl to a denied host's subdomain is not matched (exact host match only)" {
    run_hook "curl https://foo.github.com/bar"
    [ "${status}" -eq 0 ]
}

@test "a header value that happens to be dash-free but is not a URL does not trip the check" {
    run_hook 'curl -H "Authorization: token abc" https://example.com'
    [ "${status}" -eq 0 ]
}

@test "an -o output filename equal to a denied host string is not treated as the URL host, but the real URL still is" {
    run_hook "curl -o result.json https://example.com"
    [ "${status}" -eq 0 ]
}

@test "a non-literal (substitution) argument does not trip the check on its own" {
    # shellcheck disable=SC2016  # literal $URL - must reach the hook unexpanded
    run_hook 'curl -s "$URL"'
    [ "${status}" -eq 0 ]
}

@test "curl with no arguments at all is allowed" {
    run_hook "curl"
    [ "${status}" -eq 0 ]
}

@test "a non-curl command is unaffected" {
    run_hook "echo curl https://api.github.com"
    [ "${status}" -eq 0 ]
}

# --- bypass-mechanism flags: blocked outright regardless of destination ---

@test "curl -K/--config is blocked outright, even with no denied host in the visible command" {
    run_hook "curl -K config.txt https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-K/--config is not permitted'* ]]
}

@test "curl --config=<file> glued form is blocked outright" {
    run_hook "curl --config=config.txt https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-K/--config is not permitted'* ]]
}

@test "curl --connect-to is blocked outright, even to a non-denied-looking URL" {
    run_hook "curl --connect-to safe.example:443:api.github.com:443 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'--connect-to is not permitted'* ]]
}
