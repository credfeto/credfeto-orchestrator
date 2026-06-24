#!/bin/bash
# Agent entrypoint: validates required environment variables, configures
# git identity from env vars, then delegates to claude with all arguments verbatim.
# The prompt is expected on stdin (piped in by the caller via oneshot).

set -euo pipefail

die() { printf '\n\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || die "CLAUDE_CODE_OAUTH_TOKEN is required but not set"
[ -n "${GIT_USER_NAME:-}" ]           || die "GIT_USER_NAME is required but not set"
[ -n "${GIT_USER_EMAIL:-}" ]          || die "GIT_USER_EMAIL is required but not set"
[ -n "${GIT_SIGNING_KEY:-}" ]         || die "GIT_SIGNING_KEY is required but not set"

# Check that the pre-commit rules checkout at /workspace/rules is up-to-date.
# Compares the SHA recorded in /workspace/rules/.env against the published SHA.
# Skipped silently when the .env is absent, curl unavailable, or remote unreachable.
# WORKSPACE_RULES_ENV overrides the .env path (used by tests).
verify_hooks_fresh() {
    local env_file="${WORKSPACE_RULES_ENV:-/workspace/rules/.env}"
    [ -f "${env_file}" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0

    local installed_sha
    installed_sha=$(grep '^SHA=' "${env_file}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]') || true
    [ -n "${installed_sha}" ] || return 0

    local remote_sha
    remote_sha=$(curl -sf --connect-timeout 3 --max-time 5 \
        "https://pre-commit.markridgwell.com/sha.txt" 2>/dev/null \
        | head -1 | tr -d '[:space:]') || true
    printf '%s' "${remote_sha}" | grep -qE '^[0-9a-fA-F]{7,40}$' 2>/dev/null \
        || remote_sha=""

    if [ -n "${remote_sha}" ] && [ "${remote_sha}" != "${installed_sha}" ]; then
        die "Pre-commit rules are out of date (installed: ${installed_sha}, latest: ${remote_sha}) — update /workspace/rules and retry"
    fi
}

verify_gpg_signing() {
    gpg-connect-agent /bye >/dev/null 2>&1 \
        || die "gpg-agent is not responding — run 'gpgconf --launch gpg-agent' on the host"
    gpg --batch --no-tty --list-secret-keys "${GIT_SIGNING_KEY}" >/dev/null 2>&1 \
        || die "Signing key ${GIT_SIGNING_KEY} not found in GPG keyring — import it with 'gpg --import'"
    printf 'test' | gpg --batch --no-tty --armor --detach-sign \
        --default-key "${GIT_SIGNING_KEY}" --output - >/dev/null 2>&1 \
        || die "GPG signing test failed — ensure key ${GIT_SIGNING_KEY} is unlocked and the agent is accessible"
}

verify_ssh_signing() {
    [ -n "${SSH_AUTH_SOCK:-}" ] \
        || die "SSH_AUTH_SOCK is not set — SSH agent forwarding is required"
    [ -S "${SSH_AUTH_SOCK}" ] \
        || die "SSH agent socket ${SSH_AUTH_SOCK} does not exist — check SSH agent forwarding"

    local ssh_status=0
    ssh-add -l >/dev/null 2>&1 || ssh_status=$?
    case "${ssh_status}" in
        0) ;;
        1) die "SSH agent has no keys loaded — run 'ssh-add' on the host before starting the container" ;;
        *) die "SSH agent at ${SSH_AUTH_SOCK} is not responding (ssh-add -l exited ${ssh_status})" ;;
    esac

    local pubkey
    pubkey=$(ssh-add -L 2>/dev/null | head -1)
    [ -n "${pubkey}" ] || die "SSH agent returned no public keys"

    printf 'test' | ssh-keygen -Y sign -f <(printf '%s\n' "${pubkey}") -n git - >/dev/null 2>&1 \
        || die "SSH signing test failed — ensure the loaded SSH key supports signing"

    local github_auth
    github_auth=$(ssh -T git@github.com 2>&1) || true
    printf '%s' "${github_auth}" | grep -q 'successfully authenticated' \
        || die "SSH key is not authorized to access GitHub — register the public key at https://github.com/settings/keys"
}

ensure_github_known_hosts() {
    local known_hosts="${HOME}/.ssh/known_hosts"
    if grep -qsF 'github.com' "${known_hosts}"; then
        return 0
    fi
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keyscan github.com >> "${known_hosts}" 2>/dev/null
    chmod 600 "${known_hosts}"
}

# Fail fast if the workspace repo has any remote URL that is not SSH (git@github.com:).
# oneshot resets the URL to SSH before every container launch, so a non-SSH URL
# here means something has gone wrong upstream.
# WORKSPACE_REPO_DIR overrides the repo path (used by tests).
verify_repo_ssh_remotes() {
    local repo_dir="${WORKSPACE_REPO_DIR:-/workspace/repo}"
    [ -d "${repo_dir}/.git" ] || return 0

    local non_ssh_remotes
    non_ssh_remotes=$(git -C "${repo_dir}" remote -v 2>/dev/null \
        | awk '{print $2}' \
        | sort -u \
        | grep -v '^git@github\.com:' \
        || true)

    [ -z "${non_ssh_remotes}" ] && return 0

    printf '\n✗ Workspace repo has remote URL(s) not using git@github.com: SSH format:\n' >&2
    printf '%s\n' "${non_ssh_remotes}" >&2
    die "Reset with: git -C ${repo_dir} remote set-url origin git@github.com:<owner>/<repo>.git"
}

# Ensure that the user's git config does not contain any [url insteadOf] or
# [url pushInsteadOf] rules. These are only allowed in the system /etc/gitconfig.
# WORKSPACE_REPO_DIR overrides the repo path (used by tests).
verify_no_user_insteadof() {
    local repo_dir="${WORKSPACE_REPO_DIR:-/workspace/repo}"
    [ -d "${repo_dir}/.git" ] || return 0

    local violations
    violations=$(git -C "${repo_dir}" config --list --show-origin \
        | grep -iE '\.(insteadof|pushinsteadof)=' \
        | grep -v '^file:/etc/gitconfig' \
        || true)

    [ -z "${violations}" ] && return 0

    printf '\n✗ Forbidden [url "..." insteadOf] or [url "..." pushInsteadOf] rules found in user git config:\n' >&2
    printf '%s\n' "${violations}" >&2
    die "These rules are only allowed in the system /etc/gitconfig. Remove them from your local or global git config."
}

verify_gpg_signing
ensure_github_known_hosts
verify_ssh_signing
verify_repo_ssh_remotes
verify_no_user_insteadof

verify_hooks_fresh

git config --global user.name      "${GIT_USER_NAME}"
git config --global user.email     "${GIT_USER_EMAIL}"
git config --global user.signingkey "${GIT_SIGNING_KEY}"
git config --global commit.gpgsign  true

# Claude Code requires ~/.claude.json to exist; without it every invocation prints
# a "configuration file not found" warning on stderr before backing up and continuing.
# Pre-seeding it silences that noise.  Claude will overwrite it with full config on
# first run; the only required key is firstStartTime.
if [ ! -f "${HOME}/.claude.json" ]; then
    printf '{"firstStartTime":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        > "${HOME}/.claude.json"
fi

exec claude "$@"
