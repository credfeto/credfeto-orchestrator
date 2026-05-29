#!/bin/bash
# NanoClaw agent container entrypoint.
#
# Set as the container's --entrypoint by src/container-runner.ts. Runs three
# steps in order, all in one bash session so env propagates:
#
#   1. Copy host's read-only ~/.gnupg-host into a writable ~/.gnupg. gpg
#      can't acquire locks on a read-only mount, so signing / list-secret
#      / trustdb writes all fail. Host keyring stays untouched (it's RO).
#   2. /app/startup-check.sh — exits 42 on failure after writing a
#      human-readable summary into outbound.db for the host to deliver.
#      No agent tokens get spent on a doomed container.
#   3. exec bun run /app/src/index.ts — bun becomes PID 1's direct child
#      (under tini) and receives signals correctly.
#
# Stdin is consumed (was used by older v1 entrypoint for input.json — kept
# as a no-op so future spawn-arg changes that pipe data don't lose it).

set -e

cat > /tmp/input.json 2>/dev/null || true

# Persist container stdio to the session bind-mount so it survives the --rm
# cleanup that happens when the container exits. /workspace is the session
# dir on the host (data/v2-sessions/<group>/<sess>/), so the host can read
# .container.log after the container disappears — critical for diagnosing
# self-exits where the host log only sees the numeric exit code. Rotate the
# previous run's log to .prev before redirecting so the most recent crash is
# always one mv away.
CONTAINER_LOG=/workspace/.container.log
if [ -d /workspace ] && [ -w /workspace ]; then
    [ -f "$CONTAINER_LOG" ] && mv -f "$CONTAINER_LOG" "${CONTAINER_LOG}.prev" 2>/dev/null || true
    echo "===== container start $(date -Iseconds) name=${HOSTNAME:-unknown} =====" > "$CONTAINER_LOG" 2>/dev/null || true
    exec > >(tee -a "$CONTAINER_LOG") 2>&1
fi

if [ -d /home/node/.gnupg-host ] && [ ! -d /home/node/.gnupg ]; then
    cp -a /home/node/.gnupg-host /home/node/.gnupg
    chmod 700 /home/node/.gnupg
    # Prune stale keyboxd lockfiles left behind by previous container runs.
    # Format: .#lk<hex>.<hostname>.<pid> + pubring.db.lock. If we don't strip
    # these, keyboxd spins on "waiting for lock (held by <dead pid>)" and
    # every gpg call times out after 10s.
    find /home/node/.gnupg -type f \( -name '.#lk*' -o -name '*.lock' \) -delete 2>/dev/null || true
fi

# Git config defaults live in the baked-in /etc/gitconfig (root-owned, mode
# 0444 — see Dockerfile). Identity comes from the host's mounted RO
# ~/.gitconfig. The remaining piece — the global pre-commit hook wiring —
# is applied AFTER startup-check.sh so the meta-test's sanity SSH/HTTPS
# commit-pushes don't fire the hook (they're testing git/gpg/auth, not the
# linter chain). See container/system-gitconfig + Dockerfile for the
# complementary pieces.

# gh CLI auth: GH_ENTERPRISE_TOKEN is set in the Dockerfile to a placeholder
# value. OneCLI's gateway substitutes it for the real fake-proxy-token from
# its vault at egress (when the request is forwarded to GH_HOST, which is
# the local credfeto/github-api-proxy). The proxy then validates the
# fake-proxy-token, swaps it for the real GitHub PAT (which lives only in
# the proxy's .env), and forwards to api.github.com.
#
# This means: the real GitHub PAT NEVER enters this container. Even if the
# agent gets shell access, the most powerful credential it can extract is
# the placeholder — useless against api.github.com directly. All GitHub
# write operations are blocked by the proxy regardless. Code writes go via
# SSH (mounted ~/.ssh), which is a separate trust boundary.
#
# The host's ~/.config/gh is INTENTIONALLY NOT mounted (see container-runner.ts)
# for the same reason — its hosts.yml would leak the real PAT into the
# container.

/app/startup-check.sh

# core.hooksPath wiring lives in /etc/gitconfig (baked into the image —
# see container/system-gitconfig) so it applies to every git invocation
# regardless of process ancestry. No runtime env override here.

exec bun run /app/src/index.ts
