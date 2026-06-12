# syntax=docker/dockerfile:1.7
# development-agent image — locked-down agent layer on top of development-full.
#
# Adds on top of development-full:
#   - Removal of all package-management binaries (apt, dpkg) and privilege-
#     escalation binaries (sudo, su, newgrp, sg, pkexec) so the agent cannot modify its
#     own environment at runtime.
#   - /usr/local/bin/agent-entrypoint: validates the required env var and execs
#     claude with all arguments passed to `docker run`.
#   - /workspace/repo and /workspace/rules mount points (developer-owned).
#
# Runtime mounts (all supplied at `docker run` time):
#   /workspace/repo   — target repo checkout         (read/write)
#   /workspace/rules  — cs-template rules clone      (read-only)
#   /home/developer/.ssh    — SSH keys               (read-only)
#   /home/developer/.gnupg  — GPG keyring            (read/write)
#   /home/developer/.claude               — session state and memory     (read/write)
#   /home/developer/.claude/settings.json — Claude Code settings         (read-only, overlays parent)
#   /home/developer/.claude/CLAUDE.md     — global Claude instructions   (read-only, overlays parent)
#   /home/developer/.orchestrator         — oneshot state                (read/write, persists sessions)
#
# Required runtime environment variables (no default — must be set):
#   CLAUDE_CODE_OAUTH_TOKEN — Anthropic OAuth token for claude
#
# Git identity environment variables (set by oneshot from ~/.config/orchestrator/.env):
#   GIT_USER_NAME   — git user.name for commits (must be set together with GIT_USER_EMAIL)
#   GIT_USER_EMAIL  — git user.email for commits (must be set together with GIT_USER_NAME)
#   GIT_SIGNING_KEY — GPG key ID for commit signing; also enables commit.gpgsign=true
#
# Inherited environment variables (have defaults from base images; can be overridden):
#   GH_HOST             — GitHub API proxy hostname; override with "github.com" and
#                         supply GH_TOKEN for direct access bypassing the proxy
#                         (set by development-tools)
#   GH_ENTERPRISE_TOKEN — proxy placeholder token substituted by OneCLI at egress;
#                         not a real PAT — pass GH_TOKEN instead for direct access
#                         (set by development-tools)
#   DOTNET_ROOT         — .NET SDK install path (/usr/share/dotnet, do not override)
#   DOTNET_*            — .NET runtime tuning flags (do not override)
#   MSBUILDTERMINALLOGGER — MSBuild output mode (auto, do not override)
#   NUGET_PACKAGES      — NuGet package cache (/home/developer/.nuget-cache, do not override)
#   NPM_CONFIG_REGISTRY — npm registry proxy URL (https://npm.markridgwell.com/,
#                         set by development-node; override for direct npm access)
#   PATH                — extended with /home/developer/.dotnet/tools
#                         (set by development-tools; do not override)
#   TMPDIR              — temporary directory (/tmp, do not override)

# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-full:latest

# Use bash with pipefail for all subsequent RUN instructions.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# ---- Remove package management and privilege escalation tools ----------------
# Physically remove binaries the agent must never invoke.
# `rm -f` is safe on missing paths — some may not be present in every
# development-full variant.  Also clear the apt and dpkg state directories
# so re-acquiring these tools requires a full image rebuild.
# hadolint ignore=DL3009
RUN rm -f \
        /usr/bin/apt \
        /usr/bin/apt-get \
        /usr/bin/apt-cache \
        /usr/bin/apt-mark \
        /usr/bin/apt-key \
        /usr/bin/apt-config \
        /usr/bin/dpkg \
        /usr/bin/dpkg-deb \
        /usr/bin/dpkg-split \
        /usr/bin/dpkg-query \
        /usr/bin/dpkg-statoverride \
        /usr/sbin/dpkg-reconfigure \
        /usr/bin/sudo \
        /usr/sbin/sudo \
        /bin/su \
        /usr/bin/su \
        /usr/bin/newgrp \
        /usr/bin/sg \
        /usr/bin/pkexec \
    && rm -rf /var/lib/apt /var/cache/apt

# ---- Agent entrypoint --------------------------------------------------------
# Validates CLAUDE_CODE_OAUTH_TOKEN then execs claude with all passed arguments.
# Owned root:root 0755 — readable and executable by all, not modifiable by
# the unprivileged developer user the agent runs as.
COPY --chown=root:root --chmod=0755 entrypoint.sh /usr/local/bin/agent-entrypoint

# ---- Workspace mount points --------------------------------------------------
# Create the directories that will receive the runtime mounts.
# developer-owned so the agent can read/write the repo checkout without root.
RUN mkdir -p /workspace/repo /workspace/rules \
    && chown -R developer:developer /workspace \
    && chmod 0755 /workspace /workspace/repo /workspace/rules

# ---- Build-time sanity check -------------------------------------------------
# Fails the build if:
#   - any of the removed package-management or escalation binaries are still
#     reachable on PATH
#   - the entrypoint script is missing or not executable
#   - any inherited binary that the agent depends on has become unreachable
# Note: dotnet global tool list and composite checks requiring `su developer`
# were verified when development-full was built; they are not re-run here
# because su has been removed.
# hadolint ignore=DL3001,DL3059
RUN set -e; \
    echo "== verify removed package-management/escalation tools are absent =="; \
    for cmd in apt apt-get apt-cache apt-mark apt-key apt-config \
               dpkg dpkg-deb dpkg-split dpkg-query dpkg-statoverride dpkg-reconfigure \
               sudo su newgrp sg pkexec; do \
        if command -v "$cmd" >/dev/null 2>&1; then \
            echo "FATAL sanity: '$cmd' should have been removed but is still on PATH" >&2; exit 1; \
        fi; \
    done; \
    echo "== verify entrypoint is present and executable =="; \
    test -x /usr/local/bin/agent-entrypoint \
        || { echo "FATAL sanity: /usr/local/bin/agent-entrypoint is missing or not executable" >&2; exit 1; }; \
    echo "== re-verify inherited binaries (binary presence + version probe) =="; \
    for cmd in git gh dotnet python3 gpg curl sqlite3 \
               shellcheck bats shfmt checkbashisms uv ruff sqlfluff actionlint markdownlint-cli2 pre-commit \
               trufflehog hadolint dotenv-linter sqlcmd pwsh \
               yamllint ansible-lint flake8 pylint cfn-lint \
               markdownlint stylelint eslint \
               xmllint; do \
        if ! command -v "$cmd" >/dev/null 2>&1; then \
            echo "FATAL sanity: required binary '$cmd' is missing" >&2; exit 1; \
        fi; \
        if ! "$cmd" --version >/dev/null 2>&1; then \
            echo "FATAL sanity: '$cmd --version' did not exit 0" >&2; exit 1; \
        fi; \
    done; \
    echo "== composite-action-lint check (uses -h not --version) =="; \
    if ! command -v composite-action-lint >/dev/null 2>&1; then \
        echo "FATAL sanity: required binary 'composite-action-lint' is missing" >&2; exit 1; \
    fi; \
    composite-action-lint -h >/dev/null 2>&1 \
        || composite-action-lint --help >/dev/null 2>&1 \
        || { echo "FATAL sanity: composite-action-lint is not functional" >&2; exit 1; }; \
    echo "== claude check =="; \
    if ! command -v claude >/dev/null 2>&1; then \
        echo "FATAL sanity: required binary 'claude' is missing" >&2; exit 1; \
    fi; \
    claude --version >/dev/null 2>&1 || claude --help >/dev/null 2>&1 \
        || { echo "FATAL sanity: 'claude' is not functional" >&2; exit 1; }; \
    echo "== ssh check (uses -V not --version) =="; \
    if ! ssh -V >/dev/null 2>&1; then \
        echo "FATAL sanity: ssh -V did not exit 0" >&2; exit 1; \
    fi; \
    echo "== workspace directories present =="; \
    test -d /workspace/repo \
        || { echo "FATAL sanity: /workspace/repo is missing" >&2; exit 1; }; \
    test -d /workspace/rules \
        || { echo "FATAL sanity: /workspace/rules is missing" >&2; exit 1; }; \
    echo "== HTTPS clone (dnyw4l3n13/scratch — sacrificial sanity target) =="; \
    rm -rf /tmp/sanity-clone; \
    GIT_CONFIG_SYSTEM=/dev/null git clone --depth 1 \
        https://github.com/dnyw4l3n13/scratch.git /tmp/sanity-clone; \
    test -d /tmp/sanity-clone/.git; \
    rm -rf /tmp/sanity-clone; \
    echo "== all agent build-time checks passed =="

USER developer

# Bake static git settings that do not vary per deployment.
# Identity (user.name, user.email, user.signingkey) is injected at runtime
# via GIT_USER_NAME / GIT_USER_EMAIL / GIT_SIGNING_KEY env vars in entrypoint.sh.
RUN git config --global init.defaultBranch main \
    && git config --global pull.rebase true

WORKDIR /workspace/repo

ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
