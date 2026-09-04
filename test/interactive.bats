#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    setup_isolated_env
    source_interactive
    CONFIG_DIR="${XDG_CONFIG_HOME}/orchestrator"
}

teardown() {
    cleanup_stubs
}

# Writes a git stub that answers `git config --global --get <key>` from GITSTUB_<KEY> env
# vars (dots and dashes mapped to underscores, upper-cased) and exits 1 for unset keys, the
# way real git does. Every other git invocation is a no-op.
make_git_config_stub() {
    cat > "${STUB_BIN}/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "$1" = "config" ] && [ "$2" = "--global" ] && [ "$3" = "--get" ]; then
    key=$(printf '%s' "$4" | tr '.-' '__' | tr '[:lower:]' '[:upper:]')
    var="GITSTUB_${key}"
    [ -n "${!var:-}" ] || exit 1
    printf '%s\n' "${!var}"
    exit 0
fi
exit 0
GITEOF
    chmod +x "${STUB_BIN}/git"
}

# Creates a real (offline) git checkout under TEST_TMP with the given origin URL and
# outputs its path. No network: nothing is ever fetched from the origin.
make_git_checkout() {
    local origin_url="$1" dir="${TEST_TMP}/checkout"
    mkdir -p "${dir}"
    git -C "${dir}" init -q -b main
    [ -n "${origin_url}" ] && git -C "${dir}" remote add origin "${origin_url}"
    printf '%s' "${dir}"
}

# Writes a 600 token file for the canonical test owner.
make_owner_token() {
    mkdir -p "${CONFIG_DIR}/tokens"
    printf 'sk-ant-oat01-test-token' > "${CONFIG_DIR}/tokens/credfeto"
    chmod 600 "${CONFIG_DIR}/tokens/credfeto"
}

# --- source guard --------------------------------------------------------------------------

@test "sourcing interactive defines main without executing it" {
    run declare -F main
    [ "${status}" -eq 0 ]
    run declare -F resolve_repo_dir
    [ "${status}" -eq 0 ]
    run declare -F invoke_claude_interactive
    [ "${status}" -eq 0 ]
}

@test "interactive --help prints usage and exits 0" {
    run main --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: interactive"* ]]
    [[ "${output}" == *"INTERACTIVE_RULES_DIR"* ]]
}

@test "interactive dies on an unknown argument" {
    run main --bogus
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown argument: --bogus"* ]]
}

@test "INTERACTIVE_RULES_DIR defaults to HOME/work/personal/cs-template" {
    [ "${INTERACTIVE_RULES_DIR}" = "${HOME}/work/personal/cs-template" ]
}

# --- github_repo_full_from_url --------------------------------------------------------------

@test "github_repo_full_from_url parses the scp-style SSH form" {
    run github_repo_full_from_url "git@github.com:credfeto/credfeto-orchestrator.git"
    [ "${status}" -eq 0 ]
    [ "${output}" = "credfeto/credfeto-orchestrator" ]
}

@test "github_repo_full_from_url parses the ssh:// form" {
    run github_repo_full_from_url "ssh://git@github.com/credfeto/cs-template.git"
    [ "${status}" -eq 0 ]
    [ "${output}" = "credfeto/cs-template" ]
}

@test "github_repo_full_from_url parses https with and without .git and a trailing slash" {
    run github_repo_full_from_url "https://github.com/credfeto/cs-template.git"
    [ "${output}" = "credfeto/cs-template" ]
    run github_repo_full_from_url "https://github.com/credfeto/cs-template"
    [ "${output}" = "credfeto/cs-template" ]
    run github_repo_full_from_url "https://github.com/credfeto/cs-template/"
    [ "${output}" = "credfeto/cs-template" ]
}

@test "github_repo_full_from_url rejects non-GitHub and malformed URLs" {
    run github_repo_full_from_url "git@gitlab.com:credfeto/cs-template.git"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    run github_repo_full_from_url "https://github.com/credfeto"
    [ "${status}" -eq 1 ]
    run github_repo_full_from_url "https://github.com/credfeto/a/b"
    [ "${status}" -eq 1 ]
    run github_repo_full_from_url ""
    [ "${status}" -eq 1 ]
}

# --- repo resolution ------------------------------------------------------------------------

@test "resolve_repo_dir dies outside a git repository" {
    mkdir -p "${TEST_TMP}/plain"
    run resolve_repo_dir "${TEST_TMP}/plain"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not inside a git repository"* ]]
}

@test "resolve_repo_dir returns the checkout top level from a subdirectory" {
    local dir
    dir=$(make_git_checkout "")
    mkdir -p "${dir}/src/deep"
    run resolve_repo_dir "${dir}/src/deep"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(cd "${dir}" && pwd -P)" ]
}

@test "resolve_repo_full returns owner/repo from the origin remote" {
    local dir
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    run resolve_repo_full "${dir}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "credfeto/example" ]
}

@test "resolve_repo_full dies when there is no origin remote" {
    local dir
    dir=$(make_git_checkout "")
    run resolve_repo_full "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"has no origin remote"* ]]
}

@test "resolve_repo_full dies when origin is not a GitHub URL" {
    local dir
    dir=$(make_git_checkout "git@gitlab.com:credfeto/example.git")
    run resolve_repo_full "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is not a GitHub repository URL"* ]]
}

# --- rules checkout -------------------------------------------------------------------------

@test "check_rules_checkout dies when the rules dir is not a git checkout" {
    mkdir -p "${TEST_TMP}/rules"
    run check_rules_checkout "${TEST_TMP}/rules"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cs-template checkout not found"* ]]
    [[ "${output}" == *"INTERACTIVE_RULES_DIR"* ]]
}

@test "check_rules_checkout warns (does not die) when the rules checkout is not on main" {
    local dir="${TEST_TMP}/rules"
    mkdir -p "${dir}"
    git -C "${dir}" init -q -b feature/wip
    run check_rules_checkout "${dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"is on branch 'feature/wip', not main"* ]]
}

@test "check_rules_checkout is silent when the rules checkout is on main" {
    local dir="${TEST_TMP}/rules"
    mkdir -p "${dir}"
    git -C "${dir}" init -q -b main
    run check_rules_checkout "${dir}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# --- bootstrap: .env ------------------------------------------------------------------------

@test "bootstrap_orchestrator_env_file writes .env from host git config with 700/600 permissions" {
    make_git_config_stub
    export GITSTUB_USER_NAME="Test User"
    export GITSTUB_USER_EMAIL="test@example.com"
    export GITSTUB_USER_SIGNINGKEY="ABCDEF1234567890"
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 0 ]
    [ -f "${CONFIG_DIR}/.env" ]
    [ "$(stat -c '%a' "${CONFIG_DIR}")" = "700" ]
    [ "$(stat -c '%a' "${CONFIG_DIR}/.env")" = "600" ]
    grep -qx 'GIT_USER_NAME=Test User' "${CONFIG_DIR}/.env"
    grep -qx 'GIT_USER_EMAIL=test@example.com' "${CONFIG_DIR}/.env"
    grep -qx 'GIT_SIGNING_KEY=ABCDEF1234567890' "${CONFIG_DIR}/.env"
    [ "$(grep -c '^GH_' "${CONFIG_DIR}/.env")" -eq 0 ]
    [[ "${output}" == *"Created ${CONFIG_DIR}/.env"* ]]
}

@test "bootstrap_orchestrator_env_file leaves an existing .env untouched" {
    mkdir -p "${CONFIG_DIR}"
    printf 'GIT_USER_NAME=Existing\n' > "${CONFIG_DIR}/.env"
    make_git_config_stub
    export GITSTUB_USER_NAME="Other"
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 0 ]
    [ "$(cat "${CONFIG_DIR}/.env")" = "GIT_USER_NAME=Existing" ]
    [ -z "${output}" ]
}

@test "bootstrap_orchestrator_env_file dies when user.signingkey is not set" {
    make_git_config_stub
    export GITSTUB_USER_NAME="Test User"
    export GITSTUB_USER_EMAIL="test@example.com"
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"user.signingkey is not set"* ]]
    [ ! -e "${CONFIG_DIR}/.env" ]
}

@test "bootstrap_orchestrator_env_file dies when user.name or user.email is not set" {
    make_git_config_stub
    export GITSTUB_USER_SIGNINGKEY="ABCDEF1234567890"
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"user.name is not set"* ]]
    export GITSTUB_USER_NAME="Test User"
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"user.email is not set"* ]]
}

@test "bootstrap_orchestrator_env_file rejects an SSH-format signing key" {
    make_git_config_stub
    export GITSTUB_USER_NAME="Test User"
    export GITSTUB_USER_EMAIL="test@example.com"
    export GITSTUB_USER_SIGNINGKEY="/home/test/.ssh/id_ed25519.pub"
    export GITSTUB_GPG_FORMAT="ssh"
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"gpg.format is ssh"* ]]
    [ ! -e "${CONFIG_DIR}/.env" ]
}

@test "bootstrap_orchestrator_env_file writes GH_HOST and GH_TOKEN when gh is proxied and a token is available" {
    make_git_config_stub
    export GITSTUB_USER_NAME="Test User"
    export GITSTUB_USER_EMAIL="test@example.com"
    export GITSTUB_USER_SIGNINGKEY="ABCDEF1234567890"
    export GH_HOST="github-api.example.com"
    make_stub gh 'printf "ghp_stubtoken\n"'
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 0 ]
    grep -qx 'GH_HOST=github-api.example.com' "${CONFIG_DIR}/.env"
    grep -qx 'GH_TOKEN=ghp_stubtoken' "${CONFIG_DIR}/.env"
    [[ "${output}" == *"Wrote GH_HOST/GH_TOKEN"* ]]
}

@test "bootstrap_orchestrator_env_file warns and omits GH_* when gh auth token fails under a proxy" {
    make_git_config_stub
    export GITSTUB_USER_NAME="Test User"
    export GITSTUB_USER_EMAIL="test@example.com"
    export GITSTUB_USER_SIGNINGKEY="ABCDEF1234567890"
    export GH_HOST="github-api.example.com"
    make_stub gh 'exit 1'
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^GH_' "${CONFIG_DIR}/.env")" -eq 0 ]
    [[ "${output}" == *"gh inside the container will be unauthenticated"* ]]
}

@test "bootstrap_orchestrator_env_file ignores GH_HOST=github.com (no proxy)" {
    make_git_config_stub
    export GITSTUB_USER_NAME="Test User"
    export GITSTUB_USER_EMAIL="test@example.com"
    export GITSTUB_USER_SIGNINGKEY="ABCDEF1234567890"
    export GH_HOST="github.com"
    make_stub gh 'printf "ghp_stubtoken\n"'
    run bootstrap_orchestrator_env_file
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^GH_' "${CONFIG_DIR}/.env")" -eq 0 ]
}

# --- bootstrap: owner token -----------------------------------------------------------------

@test "bootstrap_owner_token is a no-op when the token file already exists" {
    make_owner_token
    make_stub claude "touch '${TEST_TMP}/claude-ran'; exit 0"
    run bootstrap_owner_token credfeto
    [ "${status}" -eq 0 ]
    [ ! -e "${TEST_TMP}/claude-ran" ]
    [ "$(cat "${CONFIG_DIR}/tokens/credfeto")" = "sk-ant-oat01-test-token" ]
}

@test "bootstrap_owner_token dies without a terminal when the token file is missing" {
    stdin_is_terminal() { return 1; }
    make_stub claude "touch '${TEST_TMP}/claude-ran'; exit 0"
    run bootstrap_owner_token credfeto
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no terminal to run 'claude setup-token'"* ]]
    [ ! -e "${TEST_TMP}/claude-ran" ]
    [ ! -e "${CONFIG_DIR}/tokens/credfeto" ]
}

@test "bootstrap_owner_token runs claude setup-token then stores the pasted token with 600 permissions" {
    stdin_is_terminal() { return 0; }
    cat > "${STUB_BIN}/claude" << 'CLAUDEEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${TEST_TMP}/claude_args"
exit 0
CLAUDEEOF
    chmod +x "${STUB_BIN}/claude"
    printf '  sk-ant-oat01-pasted  \n' | bootstrap_owner_token credfeto 2>/dev/null
    grep -qx 'setup-token' "${TEST_TMP}/claude_args"
    [ -f "${CONFIG_DIR}/tokens/credfeto" ]
    [ "$(cat "${CONFIG_DIR}/tokens/credfeto")" = "sk-ant-oat01-pasted" ]
    [ "$(stat -c '%a' "${CONFIG_DIR}/tokens/credfeto")" = "600" ]
    [ "$(stat -c '%a' "${CONFIG_DIR}/tokens")" = "700" ]
    [ "$(stat -c '%a' "${CONFIG_DIR}")" = "700" ]
    # The stored token round-trips through the same loader oneshot uses.
    [ "$(load_token_for_owner credfeto)" = "sk-ant-oat01-pasted" ]
}

@test "bootstrap_owner_token dies when claude setup-token fails" {
    stdin_is_terminal() { return 0; }
    make_stub claude 'exit 1'
    run bootstrap_owner_token credfeto <<< "sk-ant-oat01-pasted"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"claude setup-token failed"* ]]
    [ ! -e "${CONFIG_DIR}/tokens/credfeto" ]
}

@test "bootstrap_owner_token dies when no token is pasted" {
    stdin_is_terminal() { return 0; }
    make_stub claude 'exit 0'
    run bootstrap_owner_token credfeto <<< "   "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No token entered"* ]]
    [ ! -e "${CONFIG_DIR}/tokens/credfeto" ]
}

@test "bootstrap_orchestrator_config is idempotent on a fully configured host" {
    mkdir -p "${CONFIG_DIR}"
    printf 'GIT_USER_NAME=Existing\n' > "${CONFIG_DIR}/.env"
    make_owner_token
    make_stub claude "touch '${TEST_TMP}/claude-ran'; exit 0"
    make_stub git 'exit 1'
    run bootstrap_orchestrator_config credfeto
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ ! -e "${TEST_TMP}/claude-ran" ]
}

# --- build_interactive_claude_md ------------------------------------------------------------

@test "build_interactive_claude_md names the AI instructions, repo, rules and scratch paths" {
    run build_interactive_claude_md "/workspace/rules/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Read AI instructions from /workspace/rules/.ai-instructions."* ]]
    [[ "${output}" == *"${REPO_FULL} is checked out at ${CONTAINER_REPO_PATH}."* ]]
    [[ "${output}" == *"mounted read-only at ${CONTAINER_RULES_PATH}"* ]]
    [[ "${output}" == *"\$TMPDIR"* ]]
}

@test "build_interactive_claude_md carries the owner's working rules" {
    run build_interactive_claude_md "/workspace/repo/.ai-instructions"
    [[ "${output}" == *'"Approved" or "LGTM"'* ]]
    [[ "${output}" == *"Questions are not action requests"* ]]
    [[ "${output}" == *"explicitly list your assumptions"* ]]
    [[ "${output}" == *"thought sparring partner"* ]]
    [[ "${output}" == *"standingly authorises automatic git commits and pushes"* ]]
    [[ "${output}" == *"--force-with-lease"* ]]
    [[ "${output}" == *"pre-merge review pipeline"* ]]
}

@test "build_interactive_claude_md includes the shared git SSH and scratch sections" {
    run build_interactive_claude_md "/workspace/repo/.ai-instructions"
    [[ "${output}" == *"Git transport — SSH is always configured and always works"* ]]
    [[ "${output}" == *"Scratch/temporary output"* ]]
    [[ "${output}" == *"run_in_background: true"* ]]
    [[ "${output}" == *"Monitor tool"* ]]
}

@test "build_interactive_claude_md omits the one-phase-per-session orchestrator discipline" {
    run build_interactive_claude_md "/workspace/repo/.ai-instructions"
    [[ "${output}" != *"PHASE DISCIPLINE"* ]]
    [[ "${output}" != *"re-invoke"* ]]
    [[ "${output}" != *"single-shot session"* ]]
    [[ "${output}" != *"next cycle"* ]]
    [[ "${output}" != *"--add-label Blocked"* ]]
}

# --- invoke_claude_interactive --------------------------------------------------------------

# podman stub that records every argument and exits with PODMAN_STUB_EXIT (default 0);
# pull/inspect/image/secret subcommands behave as they do in the oneshot tests.
make_interactive_podman_stub() {
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "secret" ] && exit 0
[ "\$1" = "image" ] && exit 0
printf "%s\n" "\$@" >> "${TEST_TMP}/podman_args"
exit "\${PODMAN_STUB_EXIT:-0}"
STUBEOF
    chmod +x "${STUB_BIN}/podman"
}

setup_interactive_run() {
    interactive_terminal_available() { return 0; }
    make_owner_token
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_interactive_podman_stub
}

@test "invoke_claude_interactive dies without a terminal" {
    interactive_terminal_available() { return 1; }
    make_owner_token
    make_interactive_podman_stub
    run invoke_claude_interactive "# CLAUDE.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"need a terminal"* ]]
    [ ! -e "${TEST_TMP}/podman_args" ]
}

@test "invoke_claude_interactive dies when the owner has no token file (no env-var fallback)" {
    interactive_terminal_available() { return 0; }
    export CLAUDE_CODE_OAUTH_TOKEN="from-the-environment"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_interactive_podman_stub
    run invoke_claude_interactive "# CLAUDE.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No Claude OAuth token file for owner credfeto"* ]]
    [ ! -e "${TEST_TMP}/podman_args" ]
}

@test "invoke_claude_interactive attaches a TTY and uses a distinct container name" {
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    grep -qx -- '--tty' "${TEST_TMP}/podman_args"
    grep -qx -- '--interactive' "${TEST_TMP}/podman_args"
    grep -qx -- '--rm' "${TEST_TMP}/podman_args"
    grep -qx -- '--replace' "${TEST_TMP}/podman_args"
    grep -qx 'interactive-credfeto-credfeto-orchestrator' "${TEST_TMP}/podman_args"
    [ "$(grep -c 'orchestrator-credfeto$' "${TEST_TMP}/podman_args")" -eq 0 ]
}

@test "invoke_claude_interactive passes no --print, --output-format, --permission-mode or prompt" {
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    [ "$(grep -c -- '^--print$' "${TEST_TMP}/podman_args")" -eq 0 ]
    [ "$(grep -c -- '^--output-format$' "${TEST_TMP}/podman_args")" -eq 0 ]
    [ "$(grep -c -- '^--permission-mode$' "${TEST_TMP}/podman_args")" -eq 0 ]
    [ "$(grep -c -x -- '--' "${TEST_TMP}/podman_args")" -eq 0 ]
    # The image is the last podman run argument; everything after it is the claude command line.
    local expected_tail
    expected_tail=$(printf '%s\n' "${ORCHESTRATOR_IMAGE}" --model opusplan --add-dir "${CONTAINER_REPO_PATH}" "${CONTAINER_RULES_PATH}" "${CONTAINER_SCRATCH_PATH}")
    [ "$(tail -n 7 "${TEST_TMP}/podman_args")" = "${expected_tail}" ]
}

@test "invoke_claude_interactive mounts the repo, rules and scratch dirs and registers them with --add-dir" {
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    grep -qx "${REPO_WORK_DIR}:${CONTAINER_REPO_PATH}:rw" "${TEST_TMP}/podman_args"
    grep -qx "${RULES_DIR}:${CONTAINER_RULES_PATH}:ro" "${TEST_TMP}/podman_args"
    grep -q ":${CONTAINER_SCRATCH_PATH}:rw$" "${TEST_TMP}/podman_args"
    grep -qx -- '--add-dir' "${TEST_TMP}/podman_args"
    grep -qx "${CONTAINER_REPO_PATH}" "${TEST_TMP}/podman_args"
    grep -qx "${CONTAINER_RULES_PATH}" "${TEST_TMP}/podman_args"
    grep -qx "${CONTAINER_SCRATCH_PATH}" "${TEST_TMP}/podman_args"
}

@test "invoke_claude_interactive mounts the shared persistent Claude state dirs and the generated CLAUDE.md" {
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    local d
    for d in sessions session-env plans cache backups; do
        grep -qx "${CLAUDE_STATE_DIR}/${d}:/home/developer/.claude/${d}:rw" "${TEST_TMP}/podman_args"
        [ -d "${CLAUDE_STATE_DIR}/${d}" ]
    done
    grep -qx "${ORCHESTRATOR_CACHE_DIR}/global:/home/developer/.cache/orchestrator/global:rw" "${TEST_TMP}/podman_args"
    grep -q ':/home/developer/.claude/CLAUDE.md:ro$' "${TEST_TMP}/podman_args"
}

@test "invoke_claude_interactive passes the owner token as a Podman secret, never --env" {
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    grep -qx 'claude-oauth-credfeto,type=env,target=CLAUDE_CODE_OAUTH_TOKEN' "${TEST_TMP}/podman_args"
    [ "$(grep -c 'sk-ant-oat01-test-token' "${TEST_TMP}/podman_args")" -eq 0 ]
}

@test "invoke_claude_interactive creates the scratch dir under XDG_RUNTIME_DIR and removes it afterwards" {
    setup_interactive_run
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    grep -q "^${XDG_RUNTIME_DIR}/.*\.claude-scratch:${CONTAINER_SCRATCH_PATH}:rw$" "${TEST_TMP}/podman_args"
    [ -z "${CLAUDE_SCRATCH_TMPDIR}" ]
    [ -z "${CLAUDE_MD_TMPFILE}" ]
    [ "$(find "${XDG_RUNTIME_DIR}" -mindepth 1 | wc -l)" -eq 0 ]
}

@test "invoke_claude_interactive returns podman's exit status" {
    setup_interactive_run
    export PODMAN_STUB_EXIT=3
    run invoke_claude_interactive "# CLAUDE.md"
    [ "${status}" -eq 3 ]
}

@test "invoke_claude_interactive dies when CLAUDE.md content is empty" {
    setup_interactive_run
    run invoke_claude_interactive ""
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"claude_md_content is required"* ]]
    [ ! -e "${TEST_TMP}/podman_args" ]
}

@test "invoke_claude_interactive does not install the oneshot stop_ssh_agent trap" {
    setup_interactive_run
    stop_ssh_agent() { touch "${TEST_TMP}/ssh-agent-stopped"; }
    run invoke_claude_interactive "# CLAUDE.md"
    [ "${status}" -eq 0 ]
    [ ! -e "${TEST_TMP}/ssh-agent-stopped" ]
}

# --- invoke_claude keeps its behaviour after the shared-builder split ------------------------

@test "invoke_claude still passes --print, --output-format json and --permission-mode dontAsk" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--print' "${args_log}"
    grep -qx -- '--output-format' "${args_log}"
    grep -qx -- '--permission-mode' "${args_log}"
    grep -qx 'dontAsk' "${args_log}"
    [ "$(grep -c -- '^--tty$' "${args_log}")" -eq 0 ]
    grep -qx 'orchestrator-credfeto' "${args_log}"
}
