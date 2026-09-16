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

# --- denied hosts ------------------------------------------------------------

@test "curl to api.github.com is blocked" {
    run_hook "curl -fsSL https://api.github.com/repos/foo/bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.github.com' is not permitted"* ]]
}

@test "curl to github.com is blocked" {
    run_hook "curl -fsSL https://github.com/foo/bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'github.com' is not permitted"* ]]
}

@test "curl to registry.npmjs.org is blocked" {
    run_hook "curl -fsSL https://registry.npmjs.org/foo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'registry.npmjs.org' is not permitted"* ]]
}

@test "curl to raw.githubusercontent.com is blocked" {
    run_hook "curl -fsSL https://raw.githubusercontent.com/foo/bar/main/x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'raw.githubusercontent.com' is not permitted"* ]]
}

@test "curl to api.nuget.org is blocked" {
    run_hook "curl -fsSL https://api.nuget.org/v3/index.json"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.nuget.org' is not permitted"* ]]
}

@test "curl to a denied host with userinfo and a port is still matched" {
    run_hook "curl -fsSL https://user:pass@api.github.com:443/repos/foo"
    [ "${status}" -eq 2 ]
}

@test "an @ character in the URL path does not defeat the host check (path is cut before stripping userinfo)" {
    run_hook "curl -fsSL https://raw.githubusercontent.com/@"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'raw.githubusercontent.com' is not permitted"* ]]
    run_hook "curl -fsSL https://raw.githubusercontent.com/foo/bar@main"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'raw.githubusercontent.com' is not permitted"* ]]
}

@test "curl to a denied host is blocked case-insensitively" {
    run_hook "curl -fsSL https://API.GITHUB.COM/repos/foo/bar"
    [ "${status}" -eq 2 ]
}

@test "a denied host written with a trailing dot (absolute FQDN) is still blocked" {
    run_hook "curl -fsSL https://api.github.com./repos/foo/bar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.github.com' is not permitted"* ]]
}

@test "curl to a denied host via a wrapper command is still blocked" {
    run_hook "sudo curl -fsSL https://github.com/foo"
    [ "${status}" -eq 2 ]
}

@test "curl to a denied host with no flags at all is blocked" {
    run_hook "curl https://api.github.com/repos/foo"
    [ "${status}" -eq 2 ]
}

# --- allowed hosts -------------------------------------------------------------

@test "curl to a non-denied host is allowed" {
    run_hook "curl -fsSL https://example.com/foo -o /tmp/out"
    [ "${status}" -eq 0 ]
}

@test "curl to a denied host's subdomain is not matched (exact host match only)" {
    run_hook "curl -fsSL https://foo.github.com/bar"
    [ "${status}" -eq 0 ]
}

@test "a non-denied host with a trailing dot is still allowed" {
    run_hook "curl -fsSL https://example.com./foo"
    [ "${status}" -eq 0 ]
}

@test "curl -o with an output filename equal to a denied host string is still allowed for a non-denied URL" {
    run_hook "curl -fsSL -o github.com https://example.com"
    [ "${status}" -eq 0 ]
}

@test "curl --output long form is accepted" {
    run_hook "curl -fsSL --output /tmp/out https://example.com"
    [ "${status}" -eq 0 ]
}

@test "the -sf cluster is allowed" {
    run_hook "curl -sf https://example.com"
    [ "${status}" -eq 0 ]
}

@test "individually-spelled no-arg flags are allowed" {
    run_hook "curl -f -s -S -L https://example.com"
    [ "${status}" -eq 0 ]
}

@test "-v is allowed" {
    run_hook "curl -v https://example.com"
    [ "${status}" -eq 0 ]
    run_hook "curl -fsSL -v https://example.com"
    [ "${status}" -eq 0 ]
}

@test "long-form no-arg flag aliases are allowed" {
    run_hook "curl --silent --fail --show-error --location https://example.com"
    [ "${status}" -eq 0 ]
}

@test "-w/--write-out is allowed" {
    run_hook 'curl -fsSL -o /dev/null -w "http_code=%{http_code}\n" https://example.com'
    [ "${status}" -eq 0 ]
    run_hook 'curl -fsSL -o /dev/null --write-out "http_code=%{http_code}\n" https://example.com'
    [ "${status}" -eq 0 ]
}

@test "-m/--max-time is allowed" {
    run_hook "curl -fsSL -m 5 https://example.com"
    [ "${status}" -eq 0 ]
    run_hook "curl -fsSL --max-time 5 https://example.com"
    [ "${status}" -eq 0 ]
}

# --- quote-aware metachar check: {}~*?[]\ are only risky where bash would actually act on ---
# --- them, not wherever the character happens to appear literally --------------------------

@test "a double-quoted --write-out format string with curl's own %{...} codes is allowed" {
    run_hook 'curl -fsSL -o /dev/null -w "%{http_code} %{time_total} %{size_download}\n" https://example.com'
    [ "${status}" -eq 0 ]
}

@test "a single-quoted value containing brace/glob/tilde characters is allowed" {
    run_hook "curl -fsSL -w '%{http_code}[test]~x*y?z' https://example.com"
    [ "${status}" -eq 0 ]
}

@test "an unquoted brace/glob/tilde character anywhere is still rejected" {
    run_hook "curl -fsSL -w %{http_code} https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could expand into more than one word'* ]]
}

@test "a genuinely bash-significant escape inside a double-quoted value is still rejected" {
    # shellcheck disable=SC2016  # literal backslash-dollar inside the double-quoted value - must reach the hook unexpanded
    run_hook 'curl -fsSL -w "\$HOME" https://example.com'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could expand into more than one word'* ]]
}

@test "curl with no arguments at all is blocked (no URL)" {
    run_hook "curl"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'requires exactly one literal'* ]]
}

@test "a non-curl command is unaffected" {
    run_hook "echo curl https://api.github.com"
    [ "${status}" -eq 0 ]
}

# --- closed grammar: anything not on the allowlist is rejected outright -------

@test "curl -K/--config is not on the allowed flag list" {
    run_hook "curl -K config.txt https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the allowed flag list'* ]]
}

@test "curl --connect-to is not on the allowed flag list" {
    run_hook "curl --connect-to safe.example:443:api.github.com:443 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the allowed flag list'* ]]
}

@test "curl -x/--proxy is not on the allowed flag list" {
    run_hook "curl -x http://attacker.example:8080 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the allowed flag list'* ]]
}

@test "curl -H/--header is not on the allowed flag list" {
    run_hook 'curl -H "Authorization: token abc" https://example.com'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the allowed flag list'* ]]
}

@test "curl -d/--data is not on the allowed flag list" {
    run_hook 'curl -d {"a":1} https://example.com'
    [ "${status}" -eq 2 ]
}

@test "curl --url is not on the allowed flag list" {
    run_hook "curl --url https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the allowed flag list'* ]]
}

@test "an unrecognised combined short-option cluster is rejected outright" {
    run_hook "curl -sK cfg.txt https://example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the allowed flag list'* ]]
}

@test "-x glued short-option form is rejected outright" {
    run_hook "curl -xhttp://attacker.example:8080 https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not on the allowed flag list'* ]]
}

@test "more than one URL argument is rejected" {
    run_hook "curl -fsSL https://example.com https://api.github.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'more than one URL'* ]]
}

@test "a URL argument with no scheme is rejected" {
    run_hook "curl -fsSL example.com/foo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'must start with http:// or https://'* ]]
}

# --- fail-closed on any non-literal or expansion-capable argument -------------

@test "a non-literal (substitution) URL argument is rejected" {
    # shellcheck disable=SC2016  # literal $URL - must reach the hook unexpanded
    run_hook 'curl -fsSL "$URL"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'must be a literal value'* ]]
}

@test "a non-literal flag-shaped argument is rejected" {
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    run_hook 'curl "$X" https://example.com'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'must be a literal value'* ]]
}

@test "a URL argument containing brace-expansion characters is rejected" {
    run_hook "curl https://api.github.com{,}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could expand into more than one word'* ]]
}

@test "a value-flag's value hiding a denied host via brace expansion is still rejected" {
    run_hook "curl -o {,https://api.github.com/x} https://safe.example/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could expand into more than one word'* ]]
}

# --- quote-adjacent concatenation with no real expansion is folded correctly --

@test "a quote-adjacent denied host URL is still blocked" {
    run_hook "curl -fsSL https://api.github.com''/repos/foo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"curl to 'api.github.com' is not permitted"* ]]
}

@test "quote-adjacent concatenation with no expansion is otherwise still allowed for a non-denied host" {
    run_hook "curl -fsSL https://example.com''/foo"
    [ "${status}" -eq 0 ]
}

# --- DENIED_HOSTS parity with claude-settings.json's WebFetch deny list -----
#
# Reads static repo files only (no HOME/PATH/git interaction), mirroring
# test/command-allowlist-parity.bats's own approach for the exact same reason: without an
# automated check, claude-settings.json's WebFetch(domain:...) deny list is free to gain (or
# lose) a host that this hook's DENIED_HOSTS array never learns about, silently reopening the
# gap this hook exists to close for curl specifically.

# --- WRAPPERS is a subset of command-blocklist ------------------------------
#
# This hook's own header explains that its WRAPPERS/positions wrapper-detection limitation
# (only checking fixed positions 0/1, so a wrapper invoked with its own leading argument slips
# past) is currently harmless because every WRAPPERS name is also unconditionally denied by
# command-blocklist upstream, before this hook ever runs. That invariant is asserted only in a
# comment; this pins it so a future edit that adds a wrapper-like name to WRAPPERS without also
# blocklisting it (or removes one from command-blocklist) fails loudly instead of silently.

@test "every WRAPPERS entry in enforce-curl-host is also in command-blocklist" {
    local blocklist="${REPO_ROOT}/containers/base/development-full/claude-hooks/command-blocklist"
    local wrappers_line wrappers blocklist_names missing

    wrappers_line=$(grep -E '^WRAPPERS=' "${HOOK}")
    wrappers=$(printf '%s\n' "${wrappers_line}" | sed -E 's/^WRAPPERS=\((.*)\)$/\1/' | tr ' ' '\n' | sort -u)
    blocklist_names=$(grep -vE '^[[:space:]]*(#|$)' "${blocklist}" | cut -f1 | sort -u)

    [ -n "${wrappers}" ]
    [ -n "${blocklist_names}" ]
    missing=$(comm -23 <(printf '%s\n' "${wrappers}") <(printf '%s\n' "${blocklist_names}"))
    [ -z "${missing}" ]
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
