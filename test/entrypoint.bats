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

# Writes a git stub that records config calls and a claude stub that exits 0,
# and creates a fake SSH agent socket with ssh-add/ssh-keygen stubs that succeed.
setup_entrypoint_stubs() {
    cat > "${STUB_BIN}/git" << 'GITEOF'
#!/usr/bin/env bash
printf "%s\n" "$@" >> "${TEST_TMP}/git_args"
exit 0
GITEOF
    chmod +x "${STUB_BIN}/git"
    make_stub claude 'exit 0'

    # Create a fake Unix socket so [ -S "$SSH_AUTH_SOCK" ] passes.
    local sock="${TEST_TMP}/fake-agent.sock"
    python3 -c "import socket, sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "${sock}"
    export SSH_AUTH_SOCK="${sock}"

    # ssh-add stub: -l exits 0 (keys loaded), -L prints a fake public key.
    cat > "${STUB_BIN}/ssh-add" << 'STUBEOF'
#!/usr/bin/env bash
case "$1" in
    -L) printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTesting fake@test\n" ;;
    *) exit 0 ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"

    # ssh-keygen stub: always succeeds (simulates successful sign operation).
    make_stub ssh-keygen 'exit 0'

    # ssh stub: simulates a successful GitHub auth check for -T git@github.com.
    # GitHub's real ssh -T exits 1 but prints the success message; || true in the
    # entrypoint suppresses the exit code.
    cat > "${STUB_BIN}/ssh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"git@github.com"* ]]; then
    printf 'Hi testuser! You'\''ve successfully authenticated, but GitHub does not provide shell access.\n'
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/ssh"

    # gpg-connect-agent stub: always succeeds (simulates responsive gpg-agent).
    make_stub gpg-connect-agent 'exit 0'

    # gpg stub: always succeeds (simulates key present + test sign succeeds).
    make_stub gpg 'exit 0'

    # gh stub: reports git_protocol=ssh for all hosts (the expected baked-in value).
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "config" ] && [ "$2" = "list" ]; then
    printf 'hosts.github.com.git_protocol=ssh\n'
    exit 0
fi
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "git_protocol" ]; then
    printf 'ssh\n'
    exit 0
fi
if [ "$1" = "config" ] && [ "$2" = "set" ]; then
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
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

@test "entrypoint dies when GIT_USER_NAME is not set" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GIT_USER_NAME is required"* ]]
}

@test "entrypoint dies when GIT_USER_EMAIL is not set" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GIT_USER_EMAIL is required"* ]]
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

@test "entrypoint does not consume stdin before passing it to claude" {
    setup_entrypoint_stubs
    # ssh stub that reads from stdin to simulate ssh without -n consuming the prompt.
    # If entrypoint passes -n to ssh, stdin is /dev/null and claude receives the prompt.
    # If -n is absent, ssh drains the prompt and claude sees empty stdin.
    cat > "${STUB_BIN}/ssh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"git@github.com"* ]]; then
    # Real ssh -n redirects its stdin from /dev/null; simulate that here so the
    # stub only drains stdin when -n is absent (reproducing the pre-fix behaviour).
    [[ "$*" != *"-n"* ]] && cat > /dev/null
    printf 'Hi testuser! You'\''ve successfully authenticated, but GitHub does not provide shell access.\n'
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/ssh"

    cat > "${STUB_BIN}/claude" << 'STUBEOF'
#!/usr/bin/env bash
stdin=$(cat)
printf '%s' "${stdin}" > "${TEST_TMP}/claude_stdin"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/claude"

    printf 'PROMPT_CONTENT' | \
        CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}" 2>/dev/null
    grep -q 'PROMPT_CONTENT' "${TEST_TMP}/claude_stdin"
}

# --- verify_hooks_fresh -----------------------------------------------------------

# Shared env vars for verify_hooks_fresh tests.
run_entrypoint_with_hooks_env() {
    local extra_env=("$@")
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        "${extra_env[@]}" \
        bash "${ENTRYPOINT}"
}

@test "entrypoint skips hooks check when rules .env is absent" {
    setup_entrypoint_stubs
    # No WORKSPACE_RULES_ENV set and no /workspace/rules/.env on host → no-op.
    run_entrypoint_with_hooks_env WORKSPACE_RULES_ENV="${TEST_TMP}/nonexistent.env"
    [ "${status}" -eq 0 ]
}

@test "entrypoint skips hooks check when curl is unavailable" {
    setup_entrypoint_stubs
    # Create a rules .env with a SHA but hide curl so the function exits early.
    local env_file="${TEST_TMP}/rules.env"
    printf 'SHA=abc1234\n' > "${env_file}"
    make_stub curl 'exit 127'
    run_entrypoint_with_hooks_env WORKSPACE_RULES_ENV="${env_file}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint skips hooks check when remote is unreachable" {
    setup_entrypoint_stubs
    local env_file="${TEST_TMP}/rules.env"
    printf 'SHA=abc1234\n' > "${env_file}"
    # curl exits non-zero → remote_sha stays empty → no-op.
    make_stub curl 'exit 1'
    run_entrypoint_with_hooks_env WORKSPACE_RULES_ENV="${env_file}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint proceeds when installed SHA matches remote SHA" {
    setup_entrypoint_stubs
    local env_file="${TEST_TMP}/rules.env"
    printf 'SHA=abc1234\n' > "${env_file}"
    make_stub curl 'printf "abc1234\n"'
    run_entrypoint_with_hooks_env WORKSPACE_RULES_ENV="${env_file}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint dies when installed SHA is stale" {
    setup_entrypoint_stubs
    local env_file="${TEST_TMP}/rules.env"
    printf 'SHA=abc1234\n' > "${env_file}"
    make_stub curl 'printf "def5678\n"'
    run_entrypoint_with_hooks_env WORKSPACE_RULES_ENV="${env_file}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"out of date"* ]]
    [[ "${output}" == *"abc1234"* ]]
    [[ "${output}" == *"def5678"* ]]
}

@test "entrypoint skips hooks check when remote returns non-SHA output" {
    setup_entrypoint_stubs
    local env_file="${TEST_TMP}/rules.env"
    printf 'SHA=abc1234\n' > "${env_file}"
    # curl returns something that is not a valid hex SHA → treated as unreachable.
    make_stub curl 'printf "Not Found\n"'
    run_entrypoint_with_hooks_env WORKSPACE_RULES_ENV="${env_file}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint skips hooks check when rules .env has no SHA line" {
    setup_entrypoint_stubs
    local env_file="${TEST_TMP}/rules.env"
    printf 'OTHER=value\n' > "${env_file}"
    make_stub curl 'printf "def5678\n"'
    run_entrypoint_with_hooks_env WORKSPACE_RULES_ENV="${env_file}"
    [ "${status}" -eq 0 ]
}

# --- verify_ssh_signing -----------------------------------------------------------

@test "entrypoint dies when SSH_AUTH_SOCK is not set" {
    setup_entrypoint_stubs
    run env -u SSH_AUTH_SOCK \
        CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"SSH_AUTH_SOCK is not set"* ]]
}

@test "entrypoint dies when SSH_AUTH_SOCK path is not a socket" {
    setup_entrypoint_stubs
    local not_a_socket="${TEST_TMP}/regular-file"
    printf 'not a socket\n' > "${not_a_socket}"
    run env SSH_AUTH_SOCK="${not_a_socket}" \
        CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not exist"* ]]
}

@test "entrypoint dies when SSH agent has no keys loaded" {
    setup_entrypoint_stubs
    make_stub ssh-add 'exit 1'
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no keys loaded"* ]]
}

@test "entrypoint dies when SSH agent is not responding" {
    setup_entrypoint_stubs
    make_stub ssh-add 'exit 2'
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not responding"* ]]
}

@test "entrypoint dies when SSH signing test fails" {
    setup_entrypoint_stubs
    make_stub ssh-keygen 'exit 1'
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"SSH signing test failed"* ]]
}

@test "entrypoint succeeds when SSH agent has keys and signing works" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint dies when SSH key is not authorized to access GitHub" {
    setup_entrypoint_stubs
    cat > "${STUB_BIN}/ssh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"git@github.com"* ]]; then
    printf 'git@github.com: Permission denied (publickey).\n'
    exit 255
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/ssh"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"SSH key is not authorized to access GitHub"* ]]
}

# --- verify_gpg_signing -----------------------------------------------------------

@test "entrypoint dies when gpg-agent is not responding" {
    setup_entrypoint_stubs
    make_stub gpg-connect-agent 'exit 1'
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"gpg-agent is not responding"* ]]
}

@test "entrypoint dies when GIT_SIGNING_KEY is not in the GPG keyring" {
    setup_entrypoint_stubs
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    [ "${arg}" = "--list-secret-keys" ] && exit 1
done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found in GPG keyring"* ]]
}

@test "entrypoint dies when GPG signing test fails" {
    setup_entrypoint_stubs
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    [ "${arg}" = "--detach-sign" ] && exit 1
done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GPG signing test failed"* ]]
}

@test "entrypoint succeeds when GPG agent responds, key is present, and signing works" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
}

# --- .claude.json bootstrapping ------------------------------------------------

@test "entrypoint creates ~/.claude.json when it does not exist" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [ -f "${HOME}/.claude.json" ]
    grep -q '"firstStartTime"' "${HOME}/.claude.json"
}

@test "entrypoint does not overwrite ~/.claude.json when it already exists" {
    setup_entrypoint_stubs
    printf '{"firstStartTime":"2020-01-01T00:00:00.000Z","custom":"value"}\n' \
        > "${HOME}/.claude.json"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    grep -q '"custom":"value"' "${HOME}/.claude.json"
}

# --- ensure_github_known_hosts ---------------------------------------------------

@test "entrypoint calls ssh-keyscan when known_hosts does not exist" {
    setup_entrypoint_stubs
    cat > "${STUB_BIN}/ssh-keyscan" << 'STUBEOF'
#!/usr/bin/env bash
printf "github.com ssh-ed25519 FAKEKEY\n"
STUBEOF
    chmod +x "${STUB_BIN}/ssh-keyscan"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [ -f "${HOME}/.ssh/known_hosts" ]
    grep -q 'github.com' "${HOME}/.ssh/known_hosts"
}

@test "entrypoint calls ssh-keyscan when known_hosts exists but lacks github.com" {
    setup_entrypoint_stubs
    mkdir -p "${HOME}/.ssh"
    printf "bitbucket.org ssh-ed25519 OTHERKEY\n" > "${HOME}/.ssh/known_hosts"
    cat > "${STUB_BIN}/ssh-keyscan" << 'STUBEOF'
#!/usr/bin/env bash
printf "github.com ssh-ed25519 FAKEKEY\n"
STUBEOF
    chmod +x "${STUB_BIN}/ssh-keyscan"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    grep -q 'github.com' "${HOME}/.ssh/known_hosts"
}

# --- verify_repo_ssh_remotes -----------------------------------------------------

# Helper: create a fake .git/config with real remote URL entries.
# verify_repo_ssh_remotes now reads raw stored values via `git config --local --get-all`
# rather than `git remote -v`, so the git stub proxies --local reads to the real git.
# Usage: setup_repo_with_remotes <fetch_url> [<pushurl>]
setup_repo_with_remotes() {
    local fetch_url="$1"
    local push_url="${2:-}"
    local repo_dir="${TEST_TMP}/repo"

    # Init a proper git repo so `git config --local` works (it requires a valid git repo).
    /usr/bin/git init "${repo_dir}" -q

    # Append the remote config to the freshly-initialised .git/config.
    printf '[remote "origin"]\n\turl = %s\n' "${fetch_url}" >> "${repo_dir}/.git/config"
    [ -n "${push_url}" ] && printf '\tpushurl = %s\n' "${push_url}" >> "${repo_dir}/.git/config"

    cat > "${STUB_BIN}/git" << GITEOF
#!/usr/bin/env bash
printf "%s\n" "\$@" >> "${TEST_TMP}/git_args"
# Proxy --local config reads to the real git so .git/config is read correctly.
for i in "\$@"; do
    [ "\${i}" = "--local" ] && exec /usr/bin/git "\$@"
done
exit 0
GITEOF
    chmod +x "${STUB_BIN}/git"
    printf '%s' "${repo_dir}"
}

@test "entrypoint skips SSH remote check when workspace repo does not exist" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${TEST_TMP}/nonexistent" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint skips SSH remote check when .git directory is absent" {
    setup_entrypoint_stubs
    local repo_dir="${TEST_TMP}/no-git-dir"
    mkdir -p "${repo_dir}"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint succeeds when origin fetch URL uses git@github.com: SSH format" {
    setup_entrypoint_stubs
    local repo_dir
    repo_dir=$(setup_repo_with_remotes "git@github.com:credfeto/some-repo.git")
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint succeeds when origin fetch and pushurl both use git@github.com: SSH format" {
    setup_entrypoint_stubs
    local repo_dir
    repo_dir=$(setup_repo_with_remotes \
        "git@github.com:credfeto/some-repo.git" \
        "git@github.com:credfeto/some-repo.git")
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint dies when remote uses HTTPS instead of git@github.com:" {
    setup_entrypoint_stubs
    local repo_dir
    repo_dir=$(setup_repo_with_remotes "https://github.com/credfeto/some-repo.git")
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not using git@github.com:"* ]]
    [[ "${output}" == *"https://github.com"* ]]
}

@test "entrypoint dies when remote uses ssh:// URL instead of git@github.com:" {
    setup_entrypoint_stubs
    local repo_dir
    repo_dir=$(setup_repo_with_remotes "ssh://git@github.com/credfeto/some-repo.git")
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not using git@github.com:"* ]]
}

@test "entrypoint dies when pushurl is not git@github.com: even if fetch URL is correct" {
    setup_entrypoint_stubs
    local repo_dir
    repo_dir=$(setup_repo_with_remotes \
        "git@github.com:credfeto/some-repo.git" \
        "git@github-api.markridgwell.com:credfeto/some-repo.git")
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not using git@github.com:"* ]]
}

@test "entrypoint skips ssh-keyscan when github.com is already in known_hosts" {
    setup_entrypoint_stubs
    mkdir -p "${HOME}/.ssh"
    printf "github.com ssh-ed25519 EXISTINGKEY\n" > "${HOME}/.ssh/known_hosts"
    cat > "${STUB_BIN}/ssh-keyscan" << 'STUBEOF'
#!/usr/bin/env bash
printf "SHOULD_NOT_BE_CALLED\n"
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/ssh-keyscan"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    grep -qx 'github.com ssh-ed25519 EXISTINGKEY' "${HOME}/.ssh/known_hosts"
    [ "$(wc -l < "${HOME}/.ssh/known_hosts")" -eq 1 ]
}

# --- verify_no_user_insteadof -----------------------------------------------------

@test "entrypoint succeeds when insteadOf rules are only in /etc/gitconfig" {
    setup_entrypoint_stubs
    local repo_dir="${TEST_TMP}/repo"
    mkdir -p "${repo_dir}/.git"
    make_stub git 'if [[ "$*" == *"config --list --show-origin"* ]]; then
    printf "file:/etc/gitconfig\turl.git@github.com:.insteadof=https://github.com/\n"
    exit 0
fi
exit 0'

    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
}

@test "entrypoint dies when insteadOf rules are in local git config" {
    setup_entrypoint_stubs
    local repo_dir="${TEST_TMP}/repo"
    mkdir -p "${repo_dir}/.git"
    make_stub git 'if [[ "$*" == *"config --list --show-origin"* ]]; then
    printf "file:/etc/gitconfig\turl.git@github.com:.insteadof=https://github.com/\n"
    printf "file:.git/config\turl.https://x-access-token:ghp_token@github.com/.insteadof=git@github.com:\n"
    exit 0
fi
exit 0'

    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Forbidden [url \"...\" insteadOf] or [url \"...\" pushInsteadOf] rules found in user git config"* ]]
    [[ "${output}" == *"file:.git/config"* ]]
}

@test "entrypoint dies when pushInsteadOf rules are in global git config" {
    setup_entrypoint_stubs
    local repo_dir="${TEST_TMP}/repo"
    mkdir -p "${repo_dir}/.git"
    make_stub git 'if [[ "$*" == *"config --list --show-origin"* ]]; then
    printf "file:/home/node/.gitconfig\turl.git@github.com:.pushinsteadof=https://github.com/\n"
    exit 0
fi
exit 0'

    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORKSPACE_REPO_DIR="${repo_dir}" \
        bash "${ENTRYPOINT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Forbidden [url \"...\" insteadOf] or [url \"...\" pushInsteadOf] rules found in user git config"* ]]
    [[ "${output}" == *"file:/home/node/.gitconfig"* ]]
}

# --- enforce_gh_git_protocol_ssh -------------------------------------------------

@test "entrypoint passes without warning when gh git_protocol is already ssh" {
    setup_entrypoint_stubs
    # Default gh stub already returns ssh — no warn should appear.
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"resetting to ssh"* ]]
}

@test "entrypoint warns and resets gh git_protocol when it is not ssh" {
    setup_entrypoint_stubs
    # Override gh stub: config get returns 'https', config set records args on one line.
    cat > "${STUB_BIN}/gh" << GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/gh_args"
if [ "\$1" = "config" ] && [ "\$2" = "list" ]; then
    printf 'hosts.github.com.git_protocol=https\n'
    exit 0
fi
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "git_protocol" ]; then
    printf 'https\n'
    exit 0
fi
exit 0
GHEOF
    chmod +x "${STUB_BIN}/gh"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"resetting to ssh"* ]]
    grep -q "config set git_protocol ssh" "${TEST_TMP}/gh_args"
}

@test "entrypoint checks GH_HOST when set and resets it if not ssh" {
    setup_entrypoint_stubs
    cat > "${STUB_BIN}/gh" << GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/gh_args"
if [ "\$1" = "config" ] && [ "\$2" = "list" ]; then
    printf 'hosts.github.com.git_protocol=ssh\n'
    exit 0
fi
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "git_protocol" ]; then
    # Return https when queried for the proxy host, ssh otherwise.
    for i in "\$@"; do
        [ "\${i}" = "github-api.markridgwell.com" ] && { printf 'https\n'; exit 0; }
    done
    printf 'ssh\n'
    exit 0
fi
exit 0
GHEOF
    chmod +x "${STUB_BIN}/gh"
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        GH_HOST=github-api.markridgwell.com \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"github-api.markridgwell.com"*"resetting to ssh"* ]]
    grep -q "config set git_protocol ssh --host github-api.markridgwell.com" "${TEST_TMP}/gh_args"
}

# --- image provenance logging ----------------------------------------------------

@test "entrypoint logs all five image layer SHAs at startup" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        IMAGE_SHA_DEVELOPMENT_TOOLS=abc1111 \
        IMAGE_SHA_DEVELOPMENT_NODE=abc2222 \
        IMAGE_SHA_DEVELOPMENT_PYTHON=abc3333 \
        IMAGE_SHA_DEVELOPMENT_FULL=abc4444 \
        IMAGE_SHA_DEVELOPMENT_AGENT=abc5555 \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"development-tools:   abc1111"* ]]
    [[ "${output}" == *"development-node:    abc2222"* ]]
    [[ "${output}" == *"development-python:  abc3333"* ]]
    [[ "${output}" == *"development-full:    abc4444"* ]]
    [[ "${output}" == *"development-agent:   abc5555"* ]]
}

@test "entrypoint shows unknown for image layer SHAs not set in environment" {
    setup_entrypoint_stubs
    # Explicitly unset all five IMAGE_SHA_* vars so the test is not affected by
    # values baked into the process environment when run inside an agent container.
    run env -u IMAGE_SHA_DEVELOPMENT_TOOLS \
        -u IMAGE_SHA_DEVELOPMENT_NODE \
        -u IMAGE_SHA_DEVELOPMENT_PYTHON \
        -u IMAGE_SHA_DEVELOPMENT_FULL \
        -u IMAGE_SHA_DEVELOPMENT_AGENT \
        CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"development-tools:   unknown"* ]]
    [[ "${output}" == *"development-node:    unknown"* ]]
    [[ "${output}" == *"development-python:  unknown"* ]]
    [[ "${output}" == *"development-full:    unknown"* ]]
    [[ "${output}" == *"development-agent:   unknown"* ]]
}

@test "entrypoint logs the work item URL at startup when WORK_ITEM_URL is set" {
    setup_entrypoint_stubs
    run env CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        WORK_ITEM_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1056" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Working on: https://github.com/credfeto/credfeto-orchestrator/issues/1056"* ]]
}

@test "entrypoint omits the work item URL line when WORK_ITEM_URL is not set" {
    setup_entrypoint_stubs
    run env -u WORK_ITEM_URL \
        CLAUDE_CODE_OAUTH_TOKEN=token GIT_USER_NAME="Alice" \
        GIT_USER_EMAIL="alice@example.com" GIT_SIGNING_KEY="ABCD1234" \
        bash "${ENTRYPOINT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Working on:"* ]]
}
