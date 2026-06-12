#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'

load test_helper

ENTRYPOINT="${REPO_ROOT}/containers/agent/entrypoint.sh"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# Writes a git stub that records config calls and a claude stub that exits 0.
setup_entrypoint_stubs() {
    cat > "${STUB_BIN}/git" << 'GITEOF'
#!/usr/bin/env bash
printf "%s\n" "$@" >> "${TEST_TMP}/git_args"
exit 0
GITEOF
    chmod +x "${STUB_BIN}/git"
    make_stub claude 'exit 0'
}

# --- CLAUDE_CODE_OAUTH_TOKEN validation ----------------------------------------

@test "entrypoint dies when CLAUDE_CODE_OAUTH_TOKEN is not set" {
    setup_entrypoint_stubs
    run env -u CLAUDE_CODE_OAUTH_TOKEN \
        GIT_USER_NAME="Alice" GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CLAUDE_CODE_OAUTH_TOKEN is required"* ]]
}

# --- GIT_USER_NAME / GIT_USER_EMAIL validation ---------------------------------

@test "entrypoint dies when GIT_USER_NAME is set but GIT_USER_EMAIL is absent" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GIT_USER_NAME and GIT_USER_EMAIL must both be set or both absent"* ]]
}

@test "entrypoint dies when GIT_USER_EMAIL is set but GIT_USER_NAME is absent" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GIT_USER_NAME and GIT_USER_EMAIL must both be set or both absent"* ]]
}

# --- GIT_SIGNING_KEY validation ------------------------------------------------

@test "entrypoint dies when GIT_SIGNING_KEY is not set" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_USER_EMAIL="alice@example.com" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GIT_SIGNING_KEY is required"* ]]
}

# --- git config calls ----------------------------------------------------------

@test "entrypoint configures git user.name from GIT_USER_NAME" {
    setup_entrypoint_stubs
    CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_USER_EMAIL="alice@example.com" \
        GIT_SIGNING_KEY="ABCD1234" bash "${ENTRYPOINT}" 2>/dev/null
    grep -qx 'user.name' "${TEST_TMP}/git_args"
    grep -qx 'Alice' "${TEST_TMP}/git_args"
}

@test "entrypoint configures git user.email from GIT_USER_EMAIL" {
    setup_entrypoint_stubs
    CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_USER_EMAIL="alice@example.com" \
        GIT_SIGNING_KEY="ABCD1234" bash "${ENTRYPOINT}" 2>/dev/null
    grep -qx 'user.email' "${TEST_TMP}/git_args"
    grep -qx 'alice@example.com' "${TEST_TMP}/git_args"
}

@test "entrypoint configures git user.signingkey from GIT_SIGNING_KEY" {
    setup_entrypoint_stubs
    CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_USER_EMAIL="alice@example.com" \
        GIT_SIGNING_KEY="ABCD1234" bash "${ENTRYPOINT}" 2>/dev/null
    grep -qx 'user.signingkey' "${TEST_TMP}/git_args"
    grep -qx 'ABCD1234' "${TEST_TMP}/git_args"
}

@test "entrypoint enables commit.gpgsign when GIT_SIGNING_KEY is set" {
    setup_entrypoint_stubs
    CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_USER_EMAIL="alice@example.com" \
        GIT_SIGNING_KEY="ABCD1234" bash "${ENTRYPOINT}" 2>/dev/null
    grep -qx 'commit.gpgsign' "${TEST_TMP}/git_args"
    grep -qx 'true' "${TEST_TMP}/git_args"
}

@test "entrypoint skips git identity config when both name and email are absent" {
    setup_entrypoint_stubs
    CLAUDE_CODE_OAUTH_TOKEN=token GIT_SIGNING_KEY="ABCD1234" bash "${ENTRYPOINT}" 2>/dev/null || true
    run test -f "${TEST_TMP}/git_args"
    # git stub should not have been called for identity config when both are absent
    if [ -f "${TEST_TMP}/git_args" ]; then
        run grep -qx 'user.name' "${TEST_TMP}/git_args"
        [ "${status}" -ne 0 ]
    fi
}

# --- claude delegation ---------------------------------------------------------

@test "entrypoint passes arguments through to claude" {
    setup_entrypoint_stubs
    cat > "${STUB_BIN}/claude" << 'STUBEOF'
#!/usr/bin/env bash
printf "%s\n" "$@" >> "${TEST_TMP}/claude_args"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/claude"

    CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_USER_EMAIL="alice@example.com" \
        GIT_SIGNING_KEY="ABCD1234" bash "${ENTRYPOINT}" --model opus --print 2>/dev/null
    grep -qx -- '--model' "${TEST_TMP}/claude_args"
    grep -qx 'opus' "${TEST_TMP}/claude_args"
    grep -qx -- '--print' "${TEST_TMP}/claude_args"
}
