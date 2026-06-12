#!/bin/bash
# Agent entrypoint: validates the required environment variable, configures
# git identity from env vars, then delegates to claude with all arguments verbatim.
# The prompt is expected on stdin (piped in by the caller via oneshot).

set -euo pipefail

die() { printf '\n\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# CLAUDE_CODE_OAUTH_TOKEN is the Anthropic OAuth token used by claude.
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
    || die "CLAUDE_CODE_OAUTH_TOKEN is required but not set"

# Configure git identity from env vars supplied by oneshot.
# GIT_USER_NAME and GIT_USER_EMAIL must both be set or both absent.
if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.name  "${GIT_USER_NAME}"
    git config --global user.email "${GIT_USER_EMAIL}"
elif [ -n "${GIT_USER_NAME:-}" ] || [ -n "${GIT_USER_EMAIL:-}" ]; then
    die "GIT_USER_NAME and GIT_USER_EMAIL must both be set or both absent"
fi
[ -n "${GIT_SIGNING_KEY:-}" ] \
    || die "GIT_SIGNING_KEY is required but not set"
git config --global user.signingkey "${GIT_SIGNING_KEY}"
git config --global commit.gpgsign  true

exec claude "$@"
