#!/bin/bash
# Agent entrypoint: validates the required environment variable then delegates
# to claude, passing through all arguments verbatim.
# The prompt is expected on stdin (piped in by the caller via oneshot).

set -euo pipefail

die() { printf '\n\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# CLAUDE_CODE_OAUTH_TOKEN is the Anthropic OAuth token used by claude.
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
    || die "CLAUDE_CODE_OAUTH_TOKEN is required but not set"

exec claude "$@"
