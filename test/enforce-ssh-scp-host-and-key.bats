#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-ssh-scp-host-and-key"

setup() {
    setup_isolated_env
    # Deterministic "no key" baseline regardless of what the host running
    # these tests happens to have forwarded - each test that needs a key
    # opts in explicitly via with_valid_key below.
    unset SSH_AUTH_SOCK
}

teardown() {
    cleanup_stubs
}

# Pipes a Claude Code PreToolUse hook payload for the given Bash command into
# the hook under test. status 0 = allowed, 2 = blocked (matches the hook's
# own contract).
run_hook() {
    local command="$1"
    local payload
    payload=$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')
    run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
}

# Stubs ssh-add to report one loaded identity and points SSH_AUTH_SOCK at a
# (non-existent - ssh-add itself is stubbed, so it's never dereferenced)
# socket path, matching a real forwarded-agent session with a key loaded.
with_valid_key() {
    make_stub ssh-add 'exit 0'
    export SSH_AUTH_SOCK="${TEST_TMP}/fake-agent.sock"
}

@test "ssh with no key loaded is blocked even to an allowed host" {
    run_hook "ssh dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no usable SSH key'* ]]
}

@test "scp with no key loaded is blocked even to an allowed host" {
    run_hook "scp file.txt user@dns-01.lan:/tmp/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no usable SSH key'* ]]
}

@test "ssh -V (no target) is allowed without a key" {
    run_hook "ssh -V"
    [ "${status}" -eq 0 ]
}

@test "scp with only local paths (no remote host) is allowed without a key" {
    run_hook "scp file1.txt file2.txt"
    [ "${status}" -eq 0 ]
}

@test "ssh-add present but reporting no identities is blocked" {
    make_stub ssh-add 'exit 1'
    export SSH_AUTH_SOCK="${TEST_TMP}/fake-agent.sock"
    run_hook "ssh dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no usable SSH key'* ]]
}

@test "SSH_AUTH_SOCK set but ssh-add not installed is blocked" {
    export SSH_AUTH_SOCK="${TEST_TMP}/fake-agent.sock"
    run_hook "ssh dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no usable SSH key'* ]]
}

@test "ssh to a bare .lan host is allowed with a valid key" {
    with_valid_key
    run_hook "ssh dns-01.lan"
    [ "${status}" -eq 0 ]
}

@test "ssh to a nested .dns.lan subdomain is allowed" {
    with_valid_key
    run_hook "ssh dns-01.dns.lan echo hi"
    [ "${status}" -eq 0 ]
}

@test "ssh to user@host.lan is allowed" {
    with_valid_key
    run_hook "ssh user@dns-01.lan"
    [ "${status}" -eq 0 ]
}

@test "ssh to a non-.lan host is blocked" {
    with_valid_key
    run_hook "ssh evil.example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed .lan network'* ]]
}

@test "ssh to a bare hostname with no dot is blocked" {
    with_valid_key
    run_hook "ssh myhost"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed .lan network'* ]]
}

@test "ssh -p <port> <host> skips the port value before finding the target" {
    with_valid_key
    run_hook "ssh -p 2222 dns-01.lan"
    [ "${status}" -eq 0 ]
}

@test "ssh -p<port> attached form is allowed" {
    with_valid_key
    run_hook "ssh -p2222 dns-01.lan"
    [ "${status}" -eq 0 ]
}

@test "ssh -J jump-host is blocked outright regardless of the main target" {
    with_valid_key
    run_hook "ssh -J evil.com dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-J is not permitted'* ]]
}

@test "ssh -o ProxyCommand override is blocked outright" {
    with_valid_key
    run_hook "ssh -o ProxyCommand=x dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-o is not permitted'* ]]
}

@test "ssh -F alternate config is blocked outright" {
    with_valid_key
    run_hook "ssh -F /tmp/evil.cfg dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-F is not permitted'* ]]
}

@test "ssh -L port forward is blocked outright" {
    with_valid_key
    run_hook "ssh -L 8080:evil.com:80 dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-L is not permitted'* ]]
}

@test "ssh -R remote forward is blocked outright" {
    with_valid_key
    run_hook "ssh -R 8080:localhost:80 dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-R is not permitted'* ]]
}

@test "ssh -D dynamic forward is blocked outright" {
    with_valid_key
    run_hook "ssh -D 1080 dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-D is not permitted'* ]]
}

@test "ssh target via command substitution fails closed" {
    with_valid_key
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook 'ssh $(cat host.txt)'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'non-literal argument'* ]]
}

@test "ssh via sudo wrapper is still checked (defense in depth)" {
    with_valid_key
    run_hook "sudo ssh evil.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed .lan network'* ]]
}

@test "path-qualified /usr/bin/ssh is still checked" {
    with_valid_key
    run_hook "/usr/bin/ssh evil.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed .lan network'* ]]
}

@test "ssh mentioned as an unrelated argument is not treated as an invocation" {
    run_hook "grep -r ssh ."
    [ "${status}" -eq 0 ]
}

@test "scp user@host.lan:path remote destination is allowed" {
    with_valid_key
    run_hook "scp file.txt user@dns-01.lan:/tmp/"
    [ "${status}" -eq 0 ]
}

@test "scp host.lan:path with no explicit user is allowed" {
    with_valid_key
    run_hook "scp dns-01.lan:/tmp/file.txt ."
    [ "${status}" -eq 0 ]
}

@test "scp remote source to local destination is checked" {
    with_valid_key
    run_hook "scp user@dns-01.lan:/tmp/file.txt ."
    [ "${status}" -eq 0 ]
}

@test "scp scp:// URI form is allowed for a .lan host" {
    with_valid_key
    run_hook "scp scp://user@dns-01.lan/path/file ."
    [ "${status}" -eq 0 ]
}

@test "scp to a non-.lan host is blocked" {
    with_valid_key
    run_hook "scp file.txt user@evil.example.com:/tmp/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed .lan network'* ]]
}

@test "scp scp:// URI form to a non-.lan host is blocked" {
    with_valid_key
    run_hook "scp scp://user@evil.example.com/path/file ."
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed .lan network'* ]]
}

@test "scp -J jump-host is blocked outright" {
    with_valid_key
    run_hook "scp -J evil.com file.txt dns-01.lan:/tmp/"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-J is not permitted'* ]]
}

@test "scp local relative path containing a colon is not mistaken for a host" {
    with_valid_key
    run_hook "scp ./a:b.txt dns-01.lan:/tmp/"
    [ "${status}" -eq 0 ]
}

@test "scp -c cipher value is skipped before the target" {
    with_valid_key
    run_hook "scp -c aes256-gcm file.txt user@dns-01.lan:/tmp/"
    [ "${status}" -eq 0 ]
}

@test "a failing shfmt fails closed" {
    # A stub on PATH satisfies `command -v shfmt`, so a failure here exercises
    # the "could not be parsed" branch, not the "not available" branch - the
    # latter needs shfmt entirely absent from PATH, which isn't practically
    # simulable without fragile PATH surgery (matches enforce-git-dash-c.bats,
    # which doesn't test that branch either).
    make_stub shfmt 'exit 127'
    run_hook "ssh dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed as shell'* ]]
}

@test "unparseable shell input fails closed" {
    run_hook 'ssh dns-01.lan ('
    [ "${status}" -eq 2 ]
}

@test "a command with no ssh or scp call is allowed untouched" {
    run_hook "echo hello"
    [ "${status}" -eq 0 ]
}

@test "empty command is allowed" {
    run_hook ""
    [ "${status}" -eq 0 ]
}
