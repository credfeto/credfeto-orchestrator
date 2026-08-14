#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

# shellcheck disable=SC2034  # read by run_hook in test_helper.bash, not visible to shellcheck across `load`
HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-ssh-host-and-key"

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

# Stubs ssh-add to report one loaded identity and points SSH_AUTH_SOCK at a
# (non-existent - ssh-add itself is stubbed, so it's never dereferenced)
# socket path, matching a real forwarded-agent session with a key loaded.
with_valid_key() {
    make_stub ssh-add 'exit 0'
    export SSH_AUTH_SOCK="${TEST_TMP}/fake-agent.sock"
}

# --- grammar: user@host, mandatory, no flags -----------------------------

@test "ssh user@host.lan is allowed with a valid key" {
    with_valid_key
    run_hook "ssh user@dns-01.lan"
    [ "${status}" -eq 0 ]
}

@test "ssh user@host.lan with a remote command is allowed" {
    with_valid_key
    run_hook "ssh user@dns-01.lan ls -la /tmp"
    [ "${status}" -eq 0 ]
}

@test "a bare host with no user@ is rejected - user@ is mandatory" {
    with_valid_key
    run_hook "ssh dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed user@'* ]]
}

@test "ssh with no target at all is rejected" {
    with_valid_key
    run_hook "ssh"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'requires a target'* ]]
}

@test "ssh -V (a flag instead of a target) is rejected" {
    with_valid_key
    run_hook "ssh -V"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'flags are not permitted'* ]]
}

@test "any flag before the target is rejected outright, not classified" {
    with_valid_key
    run_hook "ssh -oProxyCommand=x user@dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'flags are not permitted'* ]]
}

@test "-p port form is rejected - no flags are supported at all any more" {
    with_valid_key
    run_hook "ssh -p 2222 user@dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'flags are not permitted'* ]]
}

@test "the remote command portion is not content-restricted at all" {
    with_valid_key
    # shellcheck disable=SC2016  # literal $(date) - must reach the hook unexpanded
    run_hook 'ssh user@dns-01.lan echo "-oProxyCommand=x $(date) --anything"'
    [ "${status}" -eq 0 ]
}

# --- host validation -------------------------------------------------------

@test "a nested .dns.lan subdomain is allowed" {
    with_valid_key
    run_hook "ssh user@dns-01.dns.lan"
    [ "${status}" -eq 0 ]
}

@test "a non-.lan host is rejected" {
    with_valid_key
    run_hook "ssh user@evil.example.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed user@'* ]]
}

@test "an underscore in the user portion is allowed - part of TARGET_RE's positive charset" {
    with_valid_key
    run_hook "ssh service_account@dns-01.lan"
    [ "${status}" -eq 0 ]
}

@test "host matching is case-insensitive" {
    with_valid_key
    run_hook "ssh user@DNS-01.LAN"
    [ "${status}" -eq 0 ]
}

@test "a target with no user@ separator at all is rejected" {
    with_valid_key
    run_hook "ssh dns-01.lan.evil.com"
    [ "${status}" -eq 2 ]
}

# --- transport robustness: the round 5 bug and rounds 2-4's classes ------

@test "a real newline byte inside a quoted word no longer desyncs anything (round 5 regression)" {
    # ssh -i 'x<newline>y' evil.com - previously allowed through completely
    # unchecked (no key, no host check) due to a tab/newline-joined text
    # transport. Blocked today for two independent reasons - -i is a flag
    # (rejected outright regardless of transport) AND the transport itself
    # is now safe - so this alone doesn't isolate the transport fix; the
    # dedicated tests below do that unconfounded by the flag check (round 6
    # code review).
    run_hook $'ssh -i \'x\ny\' evil.com'
    [ "${status}" -eq 2 ]
}

@test "an embedded newline inside the target itself is rejected without going through a flag check" {
    with_valid_key
    # Isolates the transport specifically: no flag involved here at all, so
    # this can only be caught by the target word itself surviving transport
    # intact and then failing TARGET_RE (a real newline is not in the
    # allowed charset).
    run_hook $'ssh \'user@dns\n-01.lan\''
    [ "${status}" -eq 2 ]
}

@test "a trailing newline on the target is rejected, not silently stripped by \$(...) (round 6 regression)" {
    with_valid_key
    # $(...) command substitution unconditionally strips ALL trailing
    # newline bytes from its captured output, regardless of quoting - two
    # separate places in the hook used $(...) on word content (the base64
    # decode step, and target_allowed's original tr-based lowercasing) and
    # both needed fixing before this closed; a real trailing newline being
    # silently dropped meant the hook validated a shorter string than the
    # one bash actually passes to ssh.
    run_hook $'ssh \'user@dns-01.lan\n\''
    [ "${status}" -eq 2 ]
}

@test "multiple trailing newlines on the target are rejected the same way" {
    with_valid_key
    run_hook $'ssh \'user@dns-01.lan\n\n\n\''
    [ "${status}" -eq 2 ]
}

@test "a trailing carriage return on the target is rejected (control case - CR was never stripped by \$(...))" {
    with_valid_key
    run_hook $'ssh \'user@dns-01.lan\r\''
    [ "${status}" -eq 2 ]
}

@test "a real tab byte inside a quoted word does not desync word extraction" {
    with_valid_key
    run_hook $'ssh user@dns-01.lan \'a\tb\''
    [ "${status}" -eq 0 ]
}

@test "brace expansion in the target is rejected by the strict regex, no expansion-awareness needed" {
    with_valid_key
    run_hook 'ssh user@{evil,dns-01}.lan'
    [ "${status}" -eq 2 ]
}

@test "a glob metacharacter in the target is rejected by the strict regex" {
    with_valid_key
    run_hook 'ssh user@dns-01*.lan'
    [ "${status}" -eq 2 ]
}

@test "a tilde in the target is rejected by the strict regex" {
    with_valid_key
    run_hook 'ssh user@~dns-01.lan'
    [ "${status}" -eq 2 ]
}

@test "a bare backslash escape in the target is rejected by the strict regex" {
    with_valid_key
    run_hook 'ssh user@dns-\01.lan'
    [ "${status}" -eq 2 ]
}

@test "an ANSI-C quoted target is rejected (Dollar-quoted forms excluded from literal unwrap)" {
    with_valid_key
    run_hook $'ssh $\'user@dns-01.lan\''
    [ "${status}" -eq 2 ]
}

@test "command substitution as the target fails closed" {
    with_valid_key
    # shellcheck disable=SC2016  # literal $(...) - must reach the hook unexpanded
    run_hook 'ssh $(cat host.txt)'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be verified'* ]]
}

@test "a quoted target with no expansion inside it is treated as literal" {
    with_valid_key
    run_hook 'ssh "user@dns-01.lan"'
    [ "${status}" -eq 0 ]
}

# --- key precondition -------------------------------------------------------

@test "a valid target with no key loaded is blocked" {
    run_hook "ssh user@dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no usable SSH key'* ]]
}

@test "ssh-add present but reporting no identities is blocked" {
    make_stub ssh-add 'exit 1'
    export SSH_AUTH_SOCK="${TEST_TMP}/fake-agent.sock"
    run_hook "ssh user@dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no usable SSH key'* ]]
}

@test "SSH_AUTH_SOCK set but pointing at an unreachable socket is blocked" {
    # Named/scoped for what this actually exercises, not "ssh-add not
    # installed" - the real ssh-add binary is on PATH in this environment
    # (and in CI), so this test cannot force `command -v ssh-add` to fail
    # without engineering a synthetic minimal PATH, which isn't attempted
    # here (matches the same trade-off already made for the "failing shfmt"
    # test below).
    export SSH_AUTH_SOCK="${TEST_TMP}/fake-agent.sock"
    run_hook "ssh user@dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no usable SSH key'* ]]
}

@test "the key check only fires for a genuinely valid ssh invocation" {
    # An invalid target should still fail on the target check, not the key
    # check - both fail closed, but the message should be specific.
    run_hook "ssh user@evil.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed user@'* ]]
}

# --- command-name matching -------------------------------------------------

@test "path-qualified /usr/bin/ssh is still checked" {
    with_valid_key
    run_hook "/usr/bin/ssh user@evil.com"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'not in the allowed user@'* ]]
}

@test "ssh via a sudo wrapper is still checked (defense in depth)" {
    with_valid_key
    run_hook "sudo ssh user@evil.com"
    [ "${status}" -eq 2 ]
}

@test "ssh mentioned as an unrelated argument is not treated as an invocation" {
    run_hook "grep -r ssh ."
    [ "${status}" -eq 0 ]
}

@test "scp is entirely untouched by this hook - not its job any more" {
    run_hook "scp file.txt user@dns-01.lan:/tmp/"
    [ "${status}" -eq 0 ]
}

# --- fail-closed infrastructure ---------------------------------------------

@test "a failing shfmt fails closed" {
    # A stub on PATH satisfies `command -v shfmt`, so a failure here exercises
    # the "could not be parsed" branch, not the "not available" branch - the
    # latter needs shfmt entirely absent from PATH, which isn't practically
    # simulable without fragile PATH surgery.
    make_stub shfmt 'exit 127'
    run_hook "ssh user@dns-01.lan"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed as shell'* ]]
}

@test "unparseable shell input fails closed" {
    run_hook 'ssh user@dns-01.lan ('
    [ "${status}" -eq 2 ]
}

@test "a command with no ssh call is allowed untouched" {
    run_hook "echo hello"
    [ "${status}" -eq 0 ]
}

@test "empty command is allowed" {
    run_hook ""
    [ "${status}" -eq 0 ]
}
