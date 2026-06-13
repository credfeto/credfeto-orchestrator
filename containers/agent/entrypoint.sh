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

git config --global user.name      "${GIT_USER_NAME}"
git config --global user.email     "${GIT_USER_EMAIL}"
git config --global user.signingkey "${GIT_SIGNING_KEY}"
git config --global commit.gpgsign  true

exec claude "$@"
