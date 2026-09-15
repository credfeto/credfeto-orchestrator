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

@test "an -o output filename equal to a denied host string is skipped as an opaque value, not treated as the URL host" {
    run_hook "curl -o github.com https://example.com"
    [ "${status}" -eq 0 ]
}

@test "a -d data value equal to a denied host string is skipped as an opaque value" {
    run_hook "curl -d github.com https://example.com"
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

@test "curl -x/--proxy is blocked outright" {
    run_hook "curl -x http://attacker.example:8080 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'goes to the proxy address'* ]]
}

@test "curl -x glued short-option form (-xhttp://...) is blocked outright" {
    run_hook "curl -xhttp://attacker.example:8080 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'goes to the proxy address'* ]]
}

@test "curl --proxy=<value> glued form is blocked outright" {
    run_hook "curl --proxy=http://attacker.example:8080 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'goes to the proxy address'* ]]
}

@test "curl --socks5/--preproxy are blocked outright" {
    run_hook "curl --socks5 attacker.example:1080 https://safe.example/"
    [ "${status}" -eq 2 ]
    run_hook "curl --preproxy socks5://attacker.example:1080 https://safe.example/"
    [ "${status}" -eq 2 ]
}

# --- glued/expanded forms that could otherwise sneak past the host check --

@test "curl --url=<denied host> glued long-option form is blocked" {
    run_hook "curl --url=https://api.github.com/repos/foo/bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.github.com' is not permitted"* ]]
}

@test "curl --url=<non-denied host> glued long-option form is allowed" {
    run_hook "curl --url=https://example.com/foo"
    [ "${status}" -eq 0 ]
}

@test "a URL argument containing brace-expansion characters is blocked outright" {
    run_hook "curl https://api.github.com{,}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could expand into more than one word'* ]]
}

@test "a -K/cfg.txt pair hidden inside brace-expansion characters is blocked outright" {
    run_hook "curl {-K,cfg.txt} https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could expand into more than one word'* ]]
}

@test "a non-denied URL containing no expansion characters is unaffected by the brace check" {
    run_hook "curl https://example.com/foo"
    [ "${status}" -eq 0 ]
}

# --- combined short-option clusters -----------------------------------------

@test "the -fsSL cluster actually used in this repo is allowed" {
    run_hook "curl -fsSL https://example.com/foo -o /tmp/out"
    [ "${status}" -eq 0 ]
}

@test "the -sf cluster actually used in this repo is allowed" {
    run_hook "curl -sf https://example.com/foo"
    [ "${status}" -eq 0 ]
}

@test "an unrecognised combined short-option cluster is blocked outright, even one hiding -K" {
    run_hook "curl -sK cfg.txt https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'combined short flags'* ]]
}

@test "an unrecognised combined short-option cluster to a denied host is still blocked" {
    run_hook "curl -sL https://api.github.com/foo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'combined short flags'* ]]
}

# --- DENIED_HOSTS parity with claude-settings.json's WebFetch deny list -----
#
# Reads static repo files only (no HOME/PATH/git interaction), mirroring
# test/command-allowlist-parity.bats's own approach for the exact same reason: without an
# automated check, claude-settings.json's WebFetch(domain:...) deny list is free to gain (or
# lose) a host that this hook's DENIED_HOSTS array never learns about, silently reopening the
# gap this hook exists to close for curl specifically.

# --- quote-adjacent concatenation must not hide a flag/host from the checks above ----------
#
# shfmt's AST splits a word like `--connect-to''` or `https://api.github.com''` into multiple
# Parts (a Lit plus an empty SglQuoted) even though bash concatenates them into one fixed
# string with zero runtime unpredictability. literal_value must fold these back into their
# real text rather than treating the word as non-literal, or the word becomes invisible to
# every check that relies on it.

@test "a quote-adjacent --connect-to is still blocked outright" {
    # shellcheck disable=SC2016  # the '' is literal shell syntax, not a shellcheck concern here
    run_hook "curl --connect-to'' safe.example:443:api.github.com:443 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'--connect-to is not permitted'* ]]
}

@test "a quote-adjacent denied host URL is still blocked" {
    run_hook "curl https://api.github.com''/repos/foo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.github.com' is not permitted"* ]]
}

@test "a quote-adjacent -K is still blocked outright" {
    run_hook "curl -K'' https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-K/--config is not permitted'* ]]
}

@test "quote-adjacent concatenation with no expansion is otherwise still allowed for a non-denied host" {
    run_hook "curl https://example.com''/foo"
    [ "${status}" -eq 0 ]
}

# --- trailing-dot FQDN must not bypass the exact-match host check --------------------------

@test "a denied host written with a trailing dot (absolute FQDN) is still blocked" {
    run_hook "curl https://api.github.com./repos/foo/bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.github.com' is not permitted"* ]]
}

@test "a non-denied host with a trailing dot is still allowed" {
    run_hook "curl https://example.com./foo"
    [ "${status}" -eq 0 ]
}

# --- a value-flag's own value must still be checked for expansion/bypass flags -------------
#
# skip_next only ever suppresses the final host-check/classification step for a recognised
# value flag's value, never the expansion-metachar or -K/--connect-to/-x/--proxy checks: those
# run on every word regardless of position, since brace/glob expansion happens before curl (or
# this hook's own "it's just an opaque value" assumption) ever sees the word.

@test "a value-flag's value hiding a denied host via brace expansion is still blocked" {
    run_hook "curl -A {,https://api.github.com/x} https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could expand into more than one word'* ]]
}

@test "a value-flag's own ordinary value is still allowed" {
    run_hook 'curl -A "some user agent string" https://example.com'
    [ "${status}" -eq 0 ]
}

@test "enforce-curl-host's DENIED_HOSTS matches claude-settings.json's WebFetch deny domains exactly" {
    local settings="${REPO_ROOT}/containers/base/development-full/claude-settings.json"
    local settings_domains hook_domains

    settings_domains=$(jq -r '.permissions.deny[]' "${settings}" | sed -nE 's/^WebFetch\(domain:(.+)\)$/\1/p' | sort -u)
    hook_domains=$(grep -E '^DENIED_HOSTS=' "${HOOK}" | sed -E 's/^DENIED_HOSTS=\((.*)\)$/\1/' | tr ' ' '\n' | sort -u)

    [ -n "${settings_domains}" ]
    [ -n "${hook_domains}" ]
    diff <(printf '%s\n' "${settings_domains}") <(printf '%s\n' "${hook_domains}")
}
