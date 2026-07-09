#!/bin/bash
# Agent entrypoint: validates required environment variables, configures
# git identity from env vars, then delegates to claude with all arguments verbatim.
# The prompt is expected on stdin (piped in by the caller via oneshot).

set -euo pipefail

die()  { printf '\n\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\n\033[33m!\033[0m %s\n' "$*" >&2; }
info() { printf '\n\033[32m→\033[0m %s\n' "$*" >&2; }

# Log the git SHA baked into each image layer at build time. Logged before the
# required-env-var checks so provenance is visible even when required vars are missing.
info "Image layer provenance (git SHA of orchestrator commit used for each build):"
info "  development-tools:   ${IMAGE_SHA_DEVELOPMENT_TOOLS:-unknown}"
info "  development-node:    ${IMAGE_SHA_DEVELOPMENT_NODE:-unknown}"
info "  development-python:  ${IMAGE_SHA_DEVELOPMENT_PYTHON:-unknown}"
info "  development-full:    ${IMAGE_SHA_DEVELOPMENT_FULL:-unknown}"
info "  development-agent:   ${IMAGE_SHA_DEVELOPMENT_AGENT:-unknown}"

# WORK_ITEM_URL is set by oneshot when it knows which Issue/PR this invocation
# is working on. It's optional so this entrypoint stays compatible with older
# oneshot invocations and with manual/local runs that don't set it — omit the
# line entirely rather than printing a confusing "unknown".
[ -n "${WORK_ITEM_URL:-}" ] && info "Working on: ${WORK_ITEM_URL}"

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
    timeout 30 gpg-connect-agent /bye >/dev/null 2>&1 \
        || die "gpg-agent is not responding (or timed out after 30s) — run 'gpgconf --launch gpg-agent' on the host"
    gpg --batch --no-tty --list-secret-keys "${GIT_SIGNING_KEY}" >/dev/null 2>&1 \
        || die "Signing key ${GIT_SIGNING_KEY} not found in GPG keyring — import it with 'gpg --import'"
    printf 'test' | timeout 30 gpg --batch --no-tty --armor --detach-sign \
        --default-key "${GIT_SIGNING_KEY}" --output - >/dev/null 2>&1 \
        || die "GPG signing test failed (or timed out after 30s) — ensure key ${GIT_SIGNING_KEY} is unlocked and the agent is accessible"
}

verify_ssh_signing() {
    [ -n "${SSH_AUTH_SOCK:-}" ] \
        || die "SSH_AUTH_SOCK is not set — SSH agent forwarding is required"
    [ -S "${SSH_AUTH_SOCK}" ] \
        || die "SSH agent socket ${SSH_AUTH_SOCK} does not exist — check SSH agent forwarding"

    local ssh_status=0
    timeout 10 ssh-add -l >/dev/null 2>&1 || ssh_status=$?
    case "${ssh_status}" in
        0) ;;
        1) die "SSH agent has no keys loaded — run 'ssh-add' on the host before starting the container" ;;
        *) die "SSH agent at ${SSH_AUTH_SOCK} is not responding (or timed out after 10s; ssh-add -l exited ${ssh_status})" ;;
    esac

    local pubkey
    pubkey=$(ssh-add -L 2>/dev/null | head -1)
    [ -n "${pubkey}" ] || die "SSH agent returned no public keys"

    printf 'test' | ssh-keygen -Y sign -f <(printf '%s\n' "${pubkey}") -n git - >/dev/null 2>&1 \
        || die "SSH signing test failed — ensure the loaded SSH key supports signing"

    # BatchMode=yes disables any interactive prompt (host-key confirmation, password);
    # ConnectTimeout/ServerAliveInterval/ServerAliveCountMax bound both a dropped SYN
    # (previously ~127s per retry with no cap) and a stalled established connection
    # (previously only the ~2h TCP keepalive — longer than AGENT_TIMEOUT, #1099).
    local github_auth ssh_rc=0
    github_auth=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 -nT git@github.com 2>&1) || ssh_rc=$?
    if printf '%s' "${github_auth}" | grep -q 'successfully authenticated'; then
        return 0
    fi
    # GitHub always responds even on a rejected key (never silence) — the response text
    # itself, not the exit code, is what distinguishes "reached GitHub, key rejected"
    # from "never reached GitHub at all" (both can share ssh's generic exit 255).
    # Checked separately from "permission denied" below (review finding on #1099): an
    # agent offering many keys can hit GitHub's max-auth-attempts limit and disconnect
    # with this message before ever presenting the right key, which is a distinct
    # problem (too many identities offered) from that key being genuinely unregistered.
    if printf '%s' "${github_auth}" | grep -qi 'too many authentication failures'; then
        die "SSH agent offered too many keys to GitHub before trying the right one (exceeds GitHub's auth-attempt limit) — reduce the keys loaded in the agent, or use 'IdentitiesOnly=yes' with an explicit IdentityFile: ${github_auth}"
    fi
    if printf '%s' "${github_auth}" | grep -qiE 'permission denied|denied \(publickey\)'; then
        die "SSH key is not authorized to access GitHub — register the public key at https://github.com/settings/keys"
    fi
    # Deliberately no specific cause claimed here (e.g. "network failure") — this branch
    # also covers non-network failures such as host-key verification, and the raw ssh
    # output above already carries whatever detail there is (review finding on #1099).
    die "SSH to git@github.com failed (exit ${ssh_rc}): ${github_auth}"
}

# GitHub's host key is baked into the system-wide known_hosts at image build time
# (containers/agent/Dockerfile), which ssh checks automatically alongside the
# per-user file — the normal case here is a same-process no-op with no network call.
# SYSTEM_KNOWN_HOSTS overrides the system-wide path (used by tests).
# The runtime ssh-keyscan below is only a fallback for an image built before that
# change, or a system file that has somehow gone missing.
ensure_github_known_hosts() {
    local system_known_hosts="${SYSTEM_KNOWN_HOSTS:-/etc/ssh/ssh_known_hosts}"
    grep -qsF 'github.com' "${system_known_hosts}" && return 0

    local known_hosts="${HOME}/.ssh/known_hosts"
    if grep -qsF 'github.com' "${known_hosts}"; then
        return 0
    fi
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    local scanned
    scanned=$(timeout 10 ssh-keyscan github.com 2>/dev/null) || true
    [ -n "${scanned}" ] \
        || die "ssh-keyscan for github.com returned no output — cannot verify its host key, refusing to proceed with no known_hosts entry (the baked system-wide known_hosts is also missing one — is this an outdated image?)"
    printf '%s\n' "${scanned}" >> "${known_hosts}"
    chmod 600 "${known_hosts}"
}

# Ensure gh uses SSH for git operations on every host it knows about.
# GH_HOST routes API calls through the proxy, but gh also uses it for git remote
# URLs in commands like `gh pr checkout` — which would write git@<proxy>: into
# .git/config. We bake `git_protocol: ssh` into the image; this function verifies
# that setting is still in effect and re-applies it if it has been overwritten.
enforce_gh_git_protocol_ssh() {
    local hosts host current
    # Collect every host gh knows about (from its config file).
    hosts=$(gh config list 2>/dev/null | awk -F'[. ]' '/^hosts\./ {print $2}' | sort -u || true)
    # Always include the proxy host (it may not have an explicit entry yet).
    [ -n "${GH_HOST:-}" ] && hosts=$(printf '%s\n%s\n' "${hosts}" "${GH_HOST}" | sort -u)
    [ -n "${hosts}" ] || return 0
    while IFS= read -r host; do
        [ -z "${host}" ] && continue
        current=$(gh config get git_protocol --host "${host}" 2>/dev/null || true)
        if [ "${current}" != "ssh" ]; then
            warn "gh git_protocol for ${host} is '${current}' — resetting to ssh"
            gh config set git_protocol ssh --host "${host}" 2>/dev/null \
                || warn "Failed to reset gh git_protocol for ${host}"
        fi
    done <<< "${hosts}"
    # Also ensure the global default is ssh.
    current=$(gh config get git_protocol 2>/dev/null || true)
    if [ "${current}" != "ssh" ]; then
        warn "gh global git_protocol is '${current}' — resetting to ssh"
        gh config set git_protocol ssh 2>/dev/null \
            || warn "Failed to reset gh global git_protocol"
    fi
}

# Fail fast if the workspace repo has any remote URL that is not SSH (git@github.com:).
# oneshot resets the URL to SSH before every container launch, so a non-SSH URL
# here means something has gone wrong upstream.
# WORKSPACE_REPO_DIR overrides the repo path (used by tests).
verify_repo_ssh_remotes() {
    local repo_dir="${WORKSPACE_REPO_DIR:-/workspace/repo}"
    [ -d "${repo_dir}/.git" ] || return 0

    # Read raw stored values from .git/config only (--local), not the insteadOf/pushInsteadOf
    # resolved URLs that `git remote -v` returns. System-level pushInsteadOf rules can rewrite
    # a correct git@github.com: fetch URL to something else in the push-URL display even though
    # the stored value is correct — causing a false-positive failure here.
    local non_ssh_remotes
    non_ssh_remotes=$({
        git -C "${repo_dir}" config --local --get-all remote.origin.url 2>/dev/null
        git -C "${repo_dir}" config --local --get-all remote.origin.pushurl 2>/dev/null
    } | sort -u | grep -v '^git@github\.com:' || true)

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

# Workspace trust is what actually gates whether Claude Code auto-loads and acts on a
# project's own .claude/settings(.local).json and .mcp.json — including hooks (e.g.
# SessionStart, PreToolUse) and MCP server definitions that execute arbitrary commands.
# --dangerously-skip-permissions does not grant this; it only bypasses interactive
# tool-call approval prompts once Claude is already running. Pre-accepting trust below
# for the repo checkout is safe ONLY because any such config it carries is verified
# below to be byte-identical to the human-reviewed version already merged to
# origin/main — some repos legitimately commit a .claude/settings.json (e.g. a
# permissions.allow linter allowlist) and that must not be treated as untrusted
# (#1133). A file that differs from origin/main, or does not exist there at all, is
# unreviewed content that could have been introduced or modified by an untrusted PR
# branch and would auto-run the instant trust is granted with no confirmation from
# Claude itself — refuse to proceed rather than silently trust it.
# Comparison is via git blob SHA (git hash-object on the working-tree file vs. git
# rev-parse on the origin/main tree entry), not `$(cat ...)` — bash command substitution
# silently strips embedded NUL bytes and would treat two files differing only by a NUL
# as identical; hash-object reads raw bytes and cannot be fooled that way (#1133 review).
# WORKSPACE_REPO_DIR overrides the repo path (used by tests).
verify_no_repo_claude_config() {
    local repo_dir="${WORKSPACE_REPO_DIR:-/workspace/repo}"
    local f rel_path local_sha main_sha
    for f in "${repo_dir}/.claude/settings.json" "${repo_dir}/.claude/settings.local.json" "${repo_dir}/.mcp.json"; do
        [ -e "${f}" ] || continue
        rel_path="${f#"${repo_dir}"/}"
        local_sha=$(git -C "${repo_dir}" hash-object "${f}" 2>/dev/null) || local_sha=""
        main_sha=$(git -C "${repo_dir}" rev-parse "origin/main:${rel_path}" 2>/dev/null) || main_sha=""
        if [ -n "${local_sha}" ] && [ -n "${main_sha}" ] && [ "${local_sha}" = "${main_sha}" ]; then
            continue
        fi
        die "Repo checkout contains ${f} that differs from the reviewed origin/main version — refusing to grant workspace trust (a checked-out hook/MCP config would auto-run once the workspace is trusted, and this checkout may contain untrusted PR content)"
    done
}

enforce_gh_git_protocol_ssh
verify_gpg_signing
ensure_github_known_hosts
verify_ssh_signing
verify_repo_ssh_remotes
verify_no_user_insteadof
verify_no_repo_claude_config

verify_hooks_fresh

git config --global user.name      "${GIT_USER_NAME}"
git config --global user.email     "${GIT_USER_EMAIL}"
git config --global user.signingkey "${GIT_SIGNING_KEY}"
git config --global commit.gpgsign  true

# Claude Code requires ~/.claude.json to exist; without it every invocation prints
# a "configuration file not found" warning on stderr before backing up and continuing.
# Pre-seeding it silences that noise.  Claude will overwrite it with full config on
# first run; the only required key is firstStartTime.
#
# Also pre-accept the workspace-trust dialog for the repo checkout (CONTAINER_REPO_PATH
# in oneshot, and this image's WORKDIR — verify_no_repo_claude_config above has already
# confirmed it carries no .claude/.mcp config of its own): every invocation is a fresh
# container with no memory of prior runs (by design, see oneshot's PHASE DISCIPLINE), so
# there is never a prior run to have accepted the interactive trust prompt, and --print
# mode has no way to show it. Without this, Claude Code silently ignores every
# permissions.allow entry in the project's own /home/developer/.claude/settings.json
# (real effect on this run is masked by --dangerously-skip-permissions also being
# passed, but the allow-list exists as its own defence-in-depth layer and should
# actually be honoured).
if [ ! -f "${HOME}/.claude.json" ]; then
    printf '{"firstStartTime":"%s","projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "${WORKSPACE_REPO_DIR:-/workspace/repo}" \
        > "${HOME}/.claude.json"
fi

exec claude "$@"
