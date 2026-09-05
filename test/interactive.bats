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

# Writes a git stub that answers `git -C <dir> config --get <key>` from GITSTUB_<KEY> env
# vars (dots and dashes mapped to underscores, upper-cased) and exits 1 for unset keys, the
# way real git does. Every other git invocation is a no-op. Seeds a complete GPG identity
# (name, email, signing key) so a test only exports what it wants to differ; unset a
# GITSTUB_* variable to make the stub report that key as missing. Records the -C directory
# of every config lookup in gitstub_dirs.
make_git_config_stub() {
    export GITSTUB_USER_NAME="${GITSTUB_USER_NAME-Test User}"
    export GITSTUB_USER_EMAIL="${GITSTUB_USER_EMAIL-test@example.com}"
    export GITSTUB_USER_SIGNINGKEY="${GITSTUB_USER_SIGNINGKEY-ABCDEF1234567890}"
    cat > "${STUB_BIN}/git" << GITEOF
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "config" ] && [ "\$4" = "--get" ]; then
    printf '%s\n' "\$2" >> "${TEST_TMP}/gitstub_dirs"
    key=\$(printf '%s' "\$5" | tr '.-' '__' | tr '[:lower:]' '[:upper:]')
    var="GITSTUB_\${key}"
    [ -n "\${!var:-}" ] || exit 1
    printf '%s\n' "\${!var}"
    exit 0
fi
exit 0
GITEOF
    chmod +x "${STUB_BIN}/git"
}

# Creates a real checkout whose local config carries one identity while the (isolated) global
# config carries another, and outputs its path: the way an includeIf or per-repo identity
# differs from `git config --global`.
make_split_identity_checkout() {
    local dir
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    git config --global user.name "Global Name"
    git config --global user.email "global@example.com"
    git config --global user.signingkey "GLOBALKEY0000000"
    git -C "${dir}" config user.name "Repo Name"
    git -C "${dir}" config user.email "repo@example.com"
    git -C "${dir}" config user.signingkey "REPOKEY000000000"
    printf '%s' "${dir}"
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

@test "INTERACTIVE_RULES_DIR defaults to WORK/personal/cs-template" {
    [ "${INTERACTIVE_RULES_DIR}" = "${WORK}/personal/cs-template" ]
    [ "${WORK}" = "${XDG_PROJECTS_DIR}" ]
}

@test "interactive disables dangling-image pruning on the developer's podman store" {
    [ "${PRUNE_DANGLING_IMAGES}" = "0" ]
    make_stub podman "printf '%s\n' \"\$@\" >> '${TEST_TMP}/podman_args'; exit 0"
    cleanup_dangling_images
    [ ! -e "${TEST_TMP}/podman_args" ]
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

@test "resolve_repo_full dies when origin is a GitHub https URL (container accepts SSH form only)" {
    local dir
    dir=$(make_git_checkout "https://github.com/credfeto/example.git")
    run resolve_repo_full "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must use the git@github.com: SSH form"* ]]
    [[ "${output}" == *"remote set-url origin git@github.com:credfeto/example.git"* ]]
}

@test "resolve_repo_dir refuses a checkout that is HOME or contains it" {
    git -C "${HOME}" init -q -b main
    mkdir -p "${HOME}/sub"
    run resolve_repo_dir "${HOME}/sub"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is your home directory or contains it"* ]]
}

@test "resolve_repo_dir refuses a linked worktree (.git is a file)" {
    local main_dir="${TEST_TMP}/main" wt="${TEST_TMP}/wt"
    mkdir -p "${main_dir}" "${TEST_TMP}/no-hooks"
    git -C "${main_dir}" init -q -b main
    fixture_commit "${main_dir}" init
    git -C "${main_dir}" worktree add -q "${wt}" -b wip
    [ -f "${wt}/.git" ]
    run resolve_repo_dir "${wt}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"linked worktree or submodule"* ]]
}

@test "github_repo_full_from_url rejects dot segments and a dotted owner" {
    run github_repo_full_from_url "git@github.com:credfeto/.."
    [ "${status}" -eq 1 ]
    run github_repo_full_from_url "git@github.com:credfeto/.git"
    [ "${status}" -eq 1 ]
    run github_repo_full_from_url "git@github.com:foo.bar/example.git"
    [ "${status}" -eq 1 ]
    run github_repo_full_from_url "git@github.com:credfeto/example.js.git"
    [ "${status}" -eq 0 ]
    [ "${output}" = "credfeto/example.js" ]
}

# --- project-level Claude config guard ------------------------------------------------------

# Commits everything staged plus a marker file in dir, with the host's global hooks
# (core.hooksPath) and signing switched off so the fixture never trips a real pre-commit hook.
fixture_commit() {
    local dir="$1" message="$2"
    printf '%s\n' "${message}" > "${dir}/.fixture-${message}"
    git -C "${dir}" add -A
    git -C "${dir}" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
        -c core.hooksPath="${TEST_TMP}/no-hooks" commit -q -m "${message}"
}

# A checkout with one commit on main that origin/main also points at.
make_committed_checkout() {
    local dir="${TEST_TMP}/checkout"
    mkdir -p "${dir}" "${TEST_TMP}/no-hooks"
    git -C "${dir}" init -q -b main
    fixture_commit "${dir}" init
    git -C "${dir}" update-ref refs/remotes/origin/main HEAD
    printf '%s' "${dir}"
}

@test "check_repo_remotes passes a plain git@github.com: origin" {
    local dir
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    run check_repo_remotes "${dir}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "check_repo_remotes dies on a non-SSH pushurl even when the fetch URL is SSH" {
    local dir
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    git -C "${dir}" remote set-url --push origin https://github.com/credfeto/example.git
    run check_repo_remotes "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"https://github.com/credfeto/example.git"* ]]
    [[ "${output}" == *"remote set-url [--push]"* ]]
}

@test "check_repo_remotes dies on a local insteadOf or pushInsteadOf rule" {
    local dir
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    git -C "${dir}" config url.https://evil.example/.insteadOf git@github.com:
    run check_repo_remotes "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"insteadOf/pushInsteadOf rules in ${dir}/.git/config"* ]]
    git -C "${dir}" config --unset url.https://evil.example/.insteadOf
    git -C "${dir}" config url.https://evil.example/.pushInsteadOf git@github.com:
    run check_repo_remotes "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"pushinsteadof=git@github.com:"* ]]
}

@test "check_repo_claude_config passes with no project-level Claude config" {
    local dir
    dir=$(make_committed_checkout)
    run check_repo_claude_config "${dir}"
    [ "${status}" -eq 0 ]
}

@test "check_repo_claude_config dies on an untracked .claude/settings.local.json" {
    local dir
    dir=$(make_committed_checkout)
    mkdir -p "${dir}/.claude"
    printf '{}' > "${dir}/.claude/settings.local.json"
    run check_repo_claude_config "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${dir}/.claude/settings.local.json differs from origin/main"* ]]
}

@test "check_repo_claude_config passes when the file is byte-identical to origin/main" {
    local dir
    dir=$(make_committed_checkout)
    mkdir -p "${dir}/.claude"
    printf '{"a":1}' > "${dir}/.claude/settings.json"
    fixture_commit "${dir}" settings
    git -C "${dir}" update-ref refs/remotes/origin/main HEAD
    run check_repo_claude_config "${dir}"
    [ "${status}" -eq 0 ]
    printf '{"a":2}' > "${dir}/.claude/settings.json"
    run check_repo_claude_config "${dir}"
    [ "${status}" -eq 1 ]
}

# --- host_to_container_path boundary ----------------------------------------------------------

@test "host_to_container_path maps on a directory boundary, not a string prefix" {
    set_repo_context "credfeto/cs" "${TEST_TMP}/personal/cs" "${TEST_TMP}/personal/cs-template"
    [ "$(host_to_container_path "${TEST_TMP}/personal/cs-template/.ai-instructions")" = "${CONTAINER_RULES_PATH}/.ai-instructions" ]
    [ "$(host_to_container_path "${TEST_TMP}/personal/cs/.ai-instructions")" = "${CONTAINER_REPO_PATH}/.ai-instructions" ]
    [ "$(host_to_container_path "${TEST_TMP}/personal/cs")" = "${CONTAINER_REPO_PATH}" ]
    [ "$(host_to_container_path "${TEST_TMP}/elsewhere/x")" = "${TEST_TMP}/elsewhere/x" ]
}

# --- git metadata change warning -------------------------------------------------------------

@test "warn_if_git_metadata_changed is silent when .git/config and hooks are unchanged" {
    local dir before
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    before=$(git_metadata_digest "${dir}")
    run warn_if_git_metadata_changed "${dir}" "${before}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "warn_if_git_metadata_changed warns when a hook or .git/config changes" {
    local dir before
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    before=$(git_metadata_digest "${dir}")
    printf '#!/bin/sh\n' > "${dir}/.git/hooks/post-checkout"
    run warn_if_git_metadata_changed "${dir}" "${before}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *".git/hooks changed during the session"* ]]
    rm "${dir}/.git/hooks/post-checkout"
    git -C "${dir}" config core.sshCommand "ssh -i /evil"
    run warn_if_git_metadata_changed "${dir}" "${before}"
    [[ "${output}" == *"changed during the session"* ]]
}

@test "git_metadata_digest ignores branch.* tracking entries but not other .git/config keys" {
    local dir before
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    before=$(git_metadata_digest "${dir}")
    # What push -u / push.autoSetupRemote write after a productive session.
    git -C "${dir}" config branch.feature.remote origin
    git -C "${dir}" config branch.feature.merge refs/heads/feature
    [ "$(git_metadata_digest "${dir}")" = "${before}" ]
    git -C "${dir}" config core.hooksPath /somewhere/else
    [ "$(git_metadata_digest "${dir}")" != "${before}" ]
    git -C "${dir}" config --unset core.hooksPath
    git -C "${dir}" config url.https://evil.example/.insteadOf git@github.com:
    [ "$(git_metadata_digest "${dir}")" != "${before}" ]
}

@test "git_metadata_digest sees a symlinked hook, a symlinked hooks dir and reordered hook lines" {
    local dir before
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    printf '#!/bin/sh\nexit 0\ncurl evil\n' > "${dir}/.git/hooks/pre-commit"
    before=$(git_metadata_digest "${dir}")
    # Same lines, different order: the payload now runs.
    printf '#!/bin/sh\ncurl evil\nexit 0\n' > "${dir}/.git/hooks/pre-commit"
    [ "$(git_metadata_digest "${dir}")" != "${before}" ]
    printf '#!/bin/sh\nexit 0\ncurl evil\n' > "${dir}/.git/hooks/pre-commit"
    [ "$(git_metadata_digest "${dir}")" = "${before}" ]
    # A hook added as a symlink to a script in the worktree.
    printf '#!/bin/sh\ncurl evil\n' > "${dir}/payload.sh"
    ln -s "${dir}/payload.sh" "${dir}/.git/hooks/post-checkout"
    [ "$(git_metadata_digest "${dir}")" != "${before}" ]
    rm "${dir}/.git/hooks/post-checkout"
    [ "$(git_metadata_digest "${dir}")" = "${before}" ]
    # hooks/ itself replaced by a symlink to a directory elsewhere.
    mv "${dir}/.git/hooks" "${dir}/hooks-elsewhere"
    ln -s "${dir}/hooks-elsewhere" "${dir}/.git/hooks"
    [ "$(git_metadata_digest "${dir}")" != "${before}" ]
}

@test "git_metadata_digest fails rather than returning an empty digest when hashing is unavailable" {
    local dir
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    hash_sha256() { cat > /dev/null; printf ''; }
    run git_metadata_digest "${dir}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
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

@test "bootstrap_orchestrator_env_file writes .env from the checkout's git identity and the host gh token with 700/600 permissions" {
    make_git_config_stub
    make_stub gh 'printf "ghp_stubtoken\n"'
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 0 ]
    [ -f "${CONFIG_DIR}/.env" ]
    [ "$(stat -c '%a' "${CONFIG_DIR}")" = "700" ]
    [ "$(stat -c '%a' "${CONFIG_DIR}/.env")" = "600" ]
    grep -qx 'GIT_USER_NAME=Test User' "${CONFIG_DIR}/.env"
    grep -qx 'GIT_USER_EMAIL=test@example.com' "${CONFIG_DIR}/.env"
    grep -qx 'GIT_SIGNING_KEY=ABCDEF1234567890' "${CONFIG_DIR}/.env"
    # Unproxied host: the token is for github.com itself.
    grep -qx 'GH_HOST=github.com' "${CONFIG_DIR}/.env"
    grep -qx 'GH_TOKEN=ghp_stubtoken' "${CONFIG_DIR}/.env"
    # Every identity lookup was made against the checkout, never --global.
    [ "$(sort -u "${TEST_TMP}/gitstub_dirs")" = "${TEST_TMP}/checkout" ]
    [[ "${output}" == *"Created ${CONFIG_DIR}/.env"* ]]
}

@test "bootstrap_orchestrator_env_file leaves an existing .env untouched" {
    mkdir -p "${CONFIG_DIR}"
    printf 'GIT_USER_NAME=Existing\n' > "${CONFIG_DIR}/.env"
    make_git_config_stub
    make_stub gh 'printf "ghp_stubtoken\n"'
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 0 ]
    [ "$(cat "${CONFIG_DIR}/.env")" = "GIT_USER_NAME=Existing" ]
    [ -z "${output}" ]
}

@test "bootstrap_orchestrator_env_file dies when user.signingkey is not set" {
    make_git_config_stub
    make_stub gh 'printf "ghp_stubtoken\n"'
    unset GITSTUB_USER_SIGNINGKEY
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"user.signingkey is not set"* ]]
    [ ! -e "${CONFIG_DIR}/.env" ]
}

@test "bootstrap_orchestrator_env_file dies when user.name or user.email is not set" {
    make_git_config_stub
    make_stub gh 'printf "ghp_stubtoken\n"'
    unset GITSTUB_USER_NAME GITSTUB_USER_EMAIL
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"user.name is not set"* ]]
    export GITSTUB_USER_NAME="Test User"
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"user.email is not set"* ]]
}

@test "bootstrap_orchestrator_env_file rejects an SSH-format signing key" {
    export GITSTUB_USER_SIGNINGKEY="/home/test/.ssh/id_ed25519.pub"
    make_git_config_stub
    make_stub gh 'printf "ghp_stubtoken\n"'
    export GITSTUB_GPG_FORMAT="ssh"
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"gpg.format is ssh"* ]]
    [ ! -e "${CONFIG_DIR}/.env" ]
}

@test "bootstrap_orchestrator_env_file writes the proxy GH_HOST and its token when gh is proxied" {
    make_git_config_stub
    export GH_HOST="github-api.example.com"
    make_stub gh 'printf "ghp_stubtoken\n"'
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 0 ]
    grep -qx 'GH_HOST=github-api.example.com' "${CONFIG_DIR}/.env"
    grep -qx 'GH_TOKEN=ghp_stubtoken' "${CONFIG_DIR}/.env"
    [[ "${output}" == *"gh token for github-api.example.com"* ]]
}

@test "bootstrap_orchestrator_env_file normalises an exported GH_HOST before writing it" {
    make_git_config_stub
    export GH_HOST="API.GitHub.com"
    make_stub gh 'printf "ghp_stubtoken\n"'
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 0 ]
    grep -qx 'GH_HOST=github.com' "${CONFIG_DIR}/.env"
}

@test "bootstrap_orchestrator_env_file dies and writes nothing when gh auth token fails" {
    make_git_config_stub
    make_stub gh 'exit 1'
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"'gh auth token' returned no token for github.com"* ]]
    [ ! -e "${CONFIG_DIR}/.env" ]
    export GH_HOST="github-api.example.com"
    run bootstrap_orchestrator_env_file "${TEST_TMP}/checkout"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"returned no token for github-api.example.com"* ]]
    [ ! -e "${CONFIG_DIR}/.env" ]
}

@test "bootstrap_orchestrator_env_file uses the checkout's effective identity, not git config --global" {
    local dir
    dir=$(make_split_identity_checkout)
    make_stub gh 'printf "ghp_stubtoken\n"'
    run bootstrap_orchestrator_env_file "${dir}"
    [ "${status}" -eq 0 ]
    grep -qx 'GIT_USER_NAME=Repo Name' "${CONFIG_DIR}/.env"
    grep -qx 'GIT_USER_EMAIL=repo@example.com' "${CONFIG_DIR}/.env"
    grep -qx 'GIT_SIGNING_KEY=REPOKEY000000000' "${CONFIG_DIR}/.env"
    [ "$(grep -c 'Global\|global@' "${CONFIG_DIR}/.env")" -eq 0 ]
}

@test "load_checkout_git_identity overrides the GIT_* variables with the checkout's identity" {
    local dir
    dir=$(make_split_identity_checkout)
    GIT_USER_NAME="From .env"
    GIT_USER_EMAIL="env@example.com"
    GIT_SIGNING_KEY="ENVKEY0000000000"
    load_checkout_git_identity "${dir}"
    [ "${GIT_USER_NAME}" = "Repo Name" ]
    [ "${GIT_USER_EMAIL}" = "repo@example.com" ]
    [ "${GIT_SIGNING_KEY}" = "REPOKEY000000000" ]
}

@test "validate_config accepts a .env without GIT_* once the checkout identity is loaded (interactive's order)" {
    local dir
    dir=$(make_split_identity_checkout)
    mkdir -p "${CONFIG_DIR}"
    printf 'GH_HOST=github-api.example.com\nGH_TOKEN=ghp_x\n' > "${CONFIG_DIR}/.env"
    make_owner_token
    load_env_config
    require_container_gh_token
    load_checkout_git_identity "${dir}"
    run validate_config credfeto
    [ "${status}" -eq 0 ]
    # The same .env fails validation in oneshot's order, which is why interactive loads first.
    load_env_config
    run validate_config credfeto
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"GIT_SIGNING_KEY is not set"* ]]
}

@test "load_checkout_git_identity dies when the checkout has no signing key" {
    local dir
    dir=$(make_git_checkout "git@github.com:credfeto/example.git")
    git -C "${dir}" config user.name "Repo Name"
    git -C "${dir}" config user.email "repo@example.com"
    run load_checkout_git_identity "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"user.signingkey is not set for ${dir}"* ]]
}

@test "require_container_gh_token dies when .env carries no GH_HOST/GH_TOKEN pair" {
    mkdir -p "${CONFIG_DIR}"
    printf 'GIT_USER_NAME=Existing\nDISCORD_WEBHOOK=https://discord.example/hook\n' > "${CONFIG_DIR}/.env"
    load_env_config
    run require_container_gh_token
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${CONFIG_DIR}/.env has no GH_HOST/GH_TOKEN pair"* ]]
    [[ "${output}" == *"gh auth token"* ]]
}

@test "require_container_gh_token passes once load_env_config has exported the pair" {
    mkdir -p "${CONFIG_DIR}"
    printf 'GH_HOST=github-api.example.com\nGH_TOKEN=ghp_x\n' > "${CONFIG_DIR}/.env"
    load_env_config
    run require_container_gh_token
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
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
    terminal_available() { return 1; }
    make_stub claude "touch '${TEST_TMP}/claude-ran'; exit 0"
    run bootstrap_owner_token credfeto
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no terminal to run 'claude setup-token'"* ]]
    [ ! -e "${TEST_TMP}/claude-ran" ]
    [ ! -e "${CONFIG_DIR}/tokens/credfeto" ]
}

@test "bootstrap_owner_token runs claude setup-token then stores the pasted token with 600 permissions" {
    terminal_available() { return 0; }
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
    terminal_available() { return 0; }
    make_stub claude 'exit 1'
    run bootstrap_owner_token credfeto <<< "sk-ant-oat01-pasted"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"claude setup-token failed"* ]]
    [ ! -e "${CONFIG_DIR}/tokens/credfeto" ]
}

@test "bootstrap_owner_token dies when no token is pasted" {
    terminal_available() { return 0; }
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
    make_stub gh 'exit 1'
    run bootstrap_orchestrator_config credfeto "${TEST_TMP}/checkout"
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
    [[ "${output}" == *"SSH is always configured and always works"* ]]
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
if [ "\$1" = "secret" ]; then
    printf "%s\n" "\$@" >> "${TEST_TMP}/podman_secret"
    exit 0
fi
if [ "\$1" = "image" ]; then
    printf "%s\n" "\$@" >> "${TEST_TMP}/podman_image"
    exit 0
fi
printf "%s\n" "\$@" >> "${TEST_TMP}/podman_args"
exit "\${PODMAN_STUB_EXIT:-0}"
STUBEOF
    chmod +x "${STUB_BIN}/podman"
}

setup_interactive_run() {
    terminal_available() { return 0; }
    make_owner_token
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_interactive_podman_stub
}

@test "invoke_claude_interactive dies without a terminal" {
    setup_interactive_run
    terminal_available() { return 1; }
    run invoke_claude_interactive "# CLAUDE.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"need a terminal"* ]]
    [ ! -e "${TEST_TMP}/podman_args" ]
}

@test "invoke_claude_interactive dies when the owner has no token file (no env-var fallback)" {
    setup_interactive_run
    rm "${CONFIG_DIR}/tokens/credfeto"
    export CLAUDE_CODE_OAUTH_TOKEN="from-the-environment"
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

@test "invoke_claude_interactive passes the owner token as a Podman secret named after its own container, never --env" {
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    grep -qx 'claude-oauth-interactive-credfeto-credfeto-orchestrator,type=env,target=CLAUDE_CODE_OAUTH_TOKEN' "${TEST_TMP}/podman_args"
    grep -qx 'claude-oauth-interactive-credfeto-credfeto-orchestrator' "${TEST_TMP}/podman_secret"
    # Never oneshot's secret name: a co-located oneshot run must not see its secret removed.
    [ "$(grep -c -- '-orchestrator-credfeto$' "${TEST_TMP}/podman_secret")" -eq 0 ]
    [ "$(grep -c 'sk-ant-oat01-test-token' "${TEST_TMP}/podman_args")" -eq 0 ]
}

@test "invoke_claude_interactive passes the gh token as GH_TOKEN for github.com and GH_ENTERPRISE_TOKEN for a proxy" {
    setup_interactive_run
    export GH_HOST="github.com" GH_ENTERPRISE_TOKEN="ghp_direct"
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    grep -qx 'gh-enterprise-token-interactive-credfeto-credfeto-orchestrator,type=env,target=GH_TOKEN' "${TEST_TMP}/podman_args"
    grep -qx 'GH_HOST=github.com' "${TEST_TMP}/podman_args"
    [ "$(grep -c 'ghp_direct' "${TEST_TMP}/podman_args")" -eq 0 ]
    rm "${TEST_TMP}/podman_args"
    export GH_HOST="github-api.example.com"
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    grep -qx 'gh-enterprise-token-interactive-credfeto-credfeto-orchestrator,type=env,target=GH_ENTERPRISE_TOKEN' "${TEST_TMP}/podman_args"
    [ "$(grep -c -- 'target=GH_TOKEN$' "${TEST_TMP}/podman_args")" -eq 0 ]
}

@test "invoke_claude_interactive never passes --replace, so a racing second launch cannot kill a live session" {
    [ "${PODMAN_REPLACE_CONTAINER}" = "0" ]
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    [ "$(grep -c -x -- '--replace' "${TEST_TMP}/podman_args")" -eq 0 ]
    grep -qx -- '--rm' "${TEST_TMP}/podman_args"
}

@test "invoke_claude_interactive never prunes the developer's images" {
    setup_interactive_run
    invoke_claude_interactive "# CLAUDE.md" 2>/dev/null
    [ ! -e "${TEST_TMP}/podman_image" ] || [ "$(grep -c '^prune$' "${TEST_TMP}/podman_image")" -eq 0 ]
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

# --- host-health checks and main() ------------------------------------------------------------

@test "check_signing_agents dies when gpg-agent, the signing key or the ssh-agent socket is missing" {
    GIT_SIGNING_KEY="ABCDEF1234567890"
    REPO_WORK_DIR="${TEST_TMP}/checkout"
    make_stub gpg-connect-agent 'exit 1'
    make_stub gpg 'exit 0'
    run check_signing_agents
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"gpg-agent is not running"* ]]
    make_stub gpg-connect-agent 'exit 0'
    make_stub gpg 'exit 1'
    run check_signing_agents
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Signing key ABCDEF1234567890"*"not in the GPG keyring"* ]]
    make_stub gpg 'exit 0'
    unset SSH_AUTH_SOCK
    run check_signing_agents
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"SSH_AUTH_SOCK is not set or is not a socket"* ]]
    export SSH_AUTH_SOCK="${TEST_TMP}/not-a-socket"
    touch "${SSH_AUTH_SOCK}"
    run check_signing_agents
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not a socket"* ]]
}

@test "check_interactive_tools requires the digest and gpg tools as well as the launch tools" {
    local tool
    for tool in git jq podman gh claude ssh-add awk gpg gpg-connect-agent gpgconf sha256sum; do
        make_stub "${tool}" 'exit 0'
    done
    # PATH restricted to the stub dir for the call only, so the host's real tools cannot
    # satisfy the check.
    PATH="${STUB_BIN}" run check_interactive_tools
    [ "${status}" -eq 0 ]
    rm "${STUB_BIN}/awk"
    PATH="${STUB_BIN}" run check_interactive_tools
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Required tool not found: awk"* ]]
    make_stub awk 'exit 0'
    rm "${STUB_BIN}/sha256sum"
    PATH="${STUB_BIN}" run check_interactive_tools
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"sha256sum (or shasum)"* ]]
    make_stub shasum 'exit 0'
    PATH="${STUB_BIN}" run check_interactive_tools
    [ "${status}" -eq 0 ]
}

# Everything main needs on a healthy host: a checkout with an SSH origin, its own identity
# and an .ai-instructions file, a rules checkout on main, a complete .env and token file,
# and PATH stubs for every tool. The signing-agent and ssh-add pre-flights are overridden
# because a test cannot create a live agent socket; they have their own tests above.
setup_main_run() {
    local dir
    dir=$(make_split_identity_checkout)
    printf '# rules\n' > "${dir}/.ai-instructions"
    git -C "${TEST_TMP}" init -q -b main rules
    INTERACTIVE_RULES_DIR="${TEST_TMP}/rules"
    mkdir -p "${CONFIG_DIR}"
    printf 'GH_HOST=github-api.example.com\nGH_TOKEN=ghp_x\nDISCORD_WEBHOOK=https://discord.example/hook\n' > "${CONFIG_DIR}/.env"
    make_owner_token
    make_interactive_podman_stub
    local tool
    for tool in gh claude ssh-add gpg gpg-connect-agent gpgconf; do
        make_stub "${tool}" "touch '${TEST_TMP}/${tool}-ran'; exit 0"
    done
    terminal_available() { return 0; }
    check_signing_agents() { touch "${TEST_TMP}/signing-agents-checked"; }
    preload_ssh_keys() { touch "${TEST_TMP}/ssh-keys-preloaded"; }
    add_gpg_podman_args() { :; }
    cd "${dir}/" || return 1
}

@test "main runs the whole launch sequence from inside a checkout and returns podman's exit status" {
    setup_main_run
    run main
    [ "${status}" -eq 0 ]
    [ -e "${TEST_TMP}/signing-agents-checked" ]
    [ -e "${TEST_TMP}/ssh-keys-preloaded" ]
    grep -qx "${TEST_TMP}/checkout:${CONTAINER_REPO_PATH}:rw" "${TEST_TMP}/podman_args"
    grep -qx "${TEST_TMP}/rules:${CONTAINER_RULES_PATH}:ro" "${TEST_TMP}/podman_args"
    # The checkout's own identity, not the (absent) .env one, reaches the container.
    grep -qx 'GIT_USER_EMAIL=repo@example.com' "${TEST_TMP}/podman_args"
    grep -qx 'GIT_SIGNING_KEY=REPOKEY000000000' "${TEST_TMP}/podman_args"
    grep -qx 'GH_HOST=github-api.example.com' "${TEST_TMP}/podman_args"
    [[ "${output}" == *"Repository: credfeto/example at ${TEST_TMP}/checkout"* ]]
    [[ "${output}" != *"changed during the session"* ]]
    # claude is only ever run for setup-token, and the token file already exists.
    [ ! -e "${TEST_TMP}/claude-ran" ]
    export PODMAN_STUB_EXIT=3
    run main
    [ "${status}" -eq 3 ]
}

@test "main warns after the session when the container changed a hook" {
    setup_main_run
    cat > "${STUB_BIN}/podman.hook" << HOOKEOF
printf '#!/bin/sh\ncurl evil\n' > '${TEST_TMP}/checkout/.git/hooks/post-checkout'
HOOKEOF
    # shellcheck disable=SC2016  # the $1 lines are the stub's own script text
    make_stub_multiline podman \
        '[ "$1" = "pull" ] && exit 0' \
        '[ "$1" = "inspect" ] && exit 1' \
        '[ "$1" = "secret" ] && exit 0' \
        '[ "$1" = "image" ] && exit 0' \
        ". '${STUB_BIN}/podman.hook'" \
        'exit 0'
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *".git/hooks changed during the session"* ]]
}

@test "main never posts a launch failure to a Discord webhook found in .env" {
    setup_main_run
    # A running container under the interactive name makes ensure_agent_container_ready die
    # through notify_discord_claude_error.
    # shellcheck disable=SC2016  # the $1/$2 lines are the stub's own script text
    make_stub_multiline podman \
        '[ "$1" = "inspect" ] && [ "$2" = "--format" ] && { printf "true\n"; exit 0; }' \
        '[ "$1" = "inspect" ] && exit 0' \
        'exit 0'
    make_stub curl "touch '${TEST_TMP}/discord-posted'; exit 0"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"already exists and is running"* ]]
    [ ! -e "${TEST_TMP}/discord-posted" ]
    [ -z "${DISCORD_WEBHOOK_URL}" ]
}

@test "main refuses a non-TTY launch before touching anything" {
    setup_main_run
    terminal_available() { return 1; }
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"need a terminal"* ]]
    [ ! -e "${TEST_TMP}/podman_args" ]
    [ ! -e "${TEST_TMP}/signing-agents-checked" ]
}

@test "main refuses a relative INTERACTIVE_RULES_DIR" {
    setup_main_run
    INTERACTIVE_RULES_DIR="rules"
    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"INTERACTIVE_RULES_DIR must be an absolute path"* ]]
    [ ! -e "${TEST_TMP}/podman_args" ]
}

# --- set_repo_context overrides ---------------------------------------------------------------

@test "set_repo_context takes optional repo work dir and rules dir, defaulting to the WORK clones" {
    set_repo_context "credfeto/example" "${TEST_TMP}/checkout" "${TEST_TMP}/rules"
    [ "${OWNER}" = "credfeto" ]
    [ "${REPO_WORK_DIR}" = "${TEST_TMP}/checkout" ]
    [ "${RULES_DIR}" = "${TEST_TMP}/rules" ]
    set_repo_context "credfeto/example"
    [ "${REPO_WORK_DIR}" = "${WORK}/credfeto/example/repo" ]
    [ "${RULES_DIR}" = "${WORK}/credfeto/example/rules" ]
}
