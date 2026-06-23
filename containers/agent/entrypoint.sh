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

verify_gpg_signing
verify_ssh_signing
ensure_github_known_hosts

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
