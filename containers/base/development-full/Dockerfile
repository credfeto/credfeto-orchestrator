# syntax=docker/dockerfile:1.7
# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-python:latest

# Use bash with pipefail for all subsequent RUN instructions so that pipes
# fail the step on any non-zero exit in the pipeline, not just the last command.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Build-time arguments ----------------------------------------------------
ARG DOTNET_TOOLS_CACHE_BUST
ARG CREDFETO_PRECOMMIT_CACHE_BUST
ARG PRECOMMIT_UPSTREAM=https://github.com/credfeto/credfeto-global-pre-commit.git
ARG MARKDOWN_LINTER_FIXER_REF=v1.5.4
# Commit hashes for external GitHub repo clones. Pins each clone to a specific,
# verified commit so a force-push or tag mutation on the upstream cannot silently
# change what is baked into the image. Update each ARG intentionally when pulling
# in new upstream changes.
ARG DOTNET_CLAUDE_KIT_COMMIT=9a9a91107596b3ac3ad1d0ad5ec5eef189e74515
ARG WSHOBSON_AGENTS_COMMIT=cc37bfdd292ce520ba1c44df7a3a70d5f8137236
ARG CC_DEVOPS_SKILLS_COMMIT=feaf2b2f3c9544aa559836731cc80e363183f788
ARG MARKDOWN_LINTER_FIXER_COMMIT=72aedc7915a0918d897b63b28d935989c054585e
ARG CREDFETO_PRECOMMIT_COMMIT=dcd40f11d35abb06db1066e27f7619c09d323356

# ---- NuGet package sources (FunFair private feeds) ---------------------------
# NuGet.Config is baked in root:root mode 0444 so the agent (running as the
# unprivileged `developer` user) can read it but cannot modify, delete, or
# replace it in place. The full /home/developer/.nuget/{,NuGet/} hierarchy is
# also root-owned 0755 — that prevents the agent from `rm`ing the locked-down
# NuGet subdir or swapping the file via a parent rename within .nuget itself.
#
# Because /home/developer/.nuget is now root-owned, dotnet's default package
# cache at ~/.nuget/packages would not be writable. We redirect it to a
# developer-owned sibling via NUGET_PACKAGES so `dotnet restore`, `dotnet tool
# install -g`, etc. continue to work without leaking write permission into
# the config subtree.
ENV NUGET_PACKAGES=/home/developer/.nuget-cache
RUN mkdir -p /home/developer/.nuget/NuGet \
    && printf '<?xml version="1.0" encoding="utf-8"?>\n\
<configuration>\n\
  <packageSources>\n\
    <clear />\n\
    <add key="Cache: api.nuget.org" value="https://api-nuget.markridgwell.com/v3/index.json" protocolVersion="3" />\n\
    <add key="Cache: FunFair" value="https://funfair-nuget.markridgwell.com/index.json" protocolVersion="3" />\n\
    <add key="Cache: FunFair (Prerelease)" value="https://funfair-prerelease-nuget.markridgwell.com/index.json" protocolVersion="3" />\n\
  </packageSources>\n\
</configuration>\n' > /home/developer/.nuget/NuGet/NuGet.Config \
    && chown -R root:root /home/developer/.nuget \
    && chmod 0755 /home/developer/.nuget /home/developer/.nuget/NuGet \
    && chmod 0444 /home/developer/.nuget/NuGet/NuGet.Config \
    && mkdir -p /home/developer/.nuget-cache \
    && chown -R developer:developer /home/developer/.nuget-cache

# ---- Claude Code (apt install — keyring baked in development-tools) ----------
# Installed here rather than in development-node because claude-code releases
# more frequently than Node/npm globals. The keyring and apt sources list entry
# were added in development-tools. DOTNET_TOOLS_CACHE_BUST (the daily date)
# busts this layer daily, ensuring any new claude-code release is picked up
# within 24 hours.
# hadolint ignore=DL3027,DL3059
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    : "${DOTNET_TOOLS_CACHE_BUST}"; \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        claude-code \
    && rm -rf /var/lib/apt/lists/*

# ---- .NET global tools (cache-bust daily so latest versions pull in) ---------
#
# Each tool gets its own RUN so:
#   - per-blob layer size stays modest (any one tool fits well under
#     typical registry edge body-size caps like Cloudflare's 100 MB).
#   - failure on one tool doesn't blow away the cache for the others.
# `: ${DOTNET_TOOLS_CACHE_BUST}` substitutes the ARG into the command
# text (no-op shell `:` discards it) so the buildkit cache key for
# every layer includes the cache-bust value — the layers re-install
# in lockstep when the ARG changes.
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.Changelog.Cmd"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.DotNet.Code.Analysis.Overrides.Cmd"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g TSQLLint"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g FunFair.BuildCheck"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g FunFair.BuildVersion"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g CWM.RoslynNavigator"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g dotnet-ef"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g ilspycmd"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Microsoft.SqlPackage"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g PowerShell"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.DotNet.Repo.Formatter"
# hadolint ignore=DL3059
RUN su developer -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g dotnet-script"

# dotnet- subcommand aliases. Several tools install only as `<name>` but
# agents invoke them via `dotnet <name>` subcommand syntax — which makes
# the dotnet CLI look for `dotnet-<name>` on PATH. Without the alias the
# call fails with "Could not execute because the specified command or
# file was not found". Bake them into the image. Idempotent: ln -sf overwrites.
# hadolint ignore=DL3059
RUN su developer -c '\
    ln -sf cscleanup             /home/developer/.dotnet/tools/dotnet-cscleanup && \
    ln -sf buildcheck            /home/developer/.dotnet/tools/dotnet-buildcheck && \
    ln -sf buildversion          /home/developer/.dotnet/tools/dotnet-buildversion && \
    ln -sf changelog             /home/developer/.dotnet/tools/dotnet-changelog && \
    ln -sf code-analysis         /home/developer/.dotnet/tools/dotnet-code-analysis && \
    ln -sf cwm-roslyn-navigator  /home/developer/.dotnet/tools/dotnet-cwm-roslyn-navigator && \
    ln -sf ilspycmd              /home/developer/.dotnet/tools/dotnet-ilspycmd && \
    ln -sf sqlpackage            /home/developer/.dotnet/tools/dotnet-sqlpackage && \
    ln -sf tsqllint              /home/developer/.dotnet/tools/dotnet-tsqllint'

# ---- dotnet-claude-kit repo (cloned for the Claude Code plugin side) ---------
# Pinned to a specific commit hash; build fails if upstream HEAD diverges.
RUN git clone --depth 1 https://github.com/codewithmukesh/dotnet-claude-kit.git /opt/dotnet-claude-kit \
    && test "$(git -C /opt/dotnet-claude-kit rev-parse HEAD)" = "${DOTNET_CLAUDE_KIT_COMMIT}" \
    && chown -R root:root /opt/dotnet-claude-kit

# ---- wshobson/agents marketplace — sparse-checkout three plugins -------------
# The full repo is ~78 plugins; we only want javascript-typescript, python-
# development, and shell-scripting. `--filter=blob:none --sparse` pulls only
# the metadata up front, then sparse-checkout materialises just those subtrees.
# Pinned to a specific commit hash; build fails if upstream HEAD diverges.
# hadolint ignore=DL3059
RUN git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/wshobson/agents.git /opt/wshobson-agents \
    && git -C /opt/wshobson-agents sparse-checkout set \
        plugins/javascript-typescript \
        plugins/python-development \
        plugins/shell-scripting \
    && test "$(git -C /opt/wshobson-agents rev-parse HEAD)" = "${WSHOBSON_AGENTS_COMMIT}" \
    && chown -R root:root /opt/wshobson-agents

# ---- akin-ozer/cc-devops-skills (GitHub Actions et al) ----------------------
# Pinned to a specific commit hash; build fails if upstream HEAD diverges.
# hadolint ignore=DL3059
RUN git clone --depth 1 https://github.com/akin-ozer/cc-devops-skills.git /opt/cc-devops-skills \
    && test "$(git -C /opt/cc-devops-skills rev-parse HEAD)" = "${CC_DEVOPS_SKILLS_COMMIT}" \
    && chown -R root:root /opt/cc-devops-skills

# ---- s2005/markdown-linter-fixer-skill (pinned) -----------------------------
# MARKDOWN_LINTER_FIXER_REF is the git tag used for the shallow clone.
# MARKDOWN_LINTER_FIXER_COMMIT is the full commit SHA that tag currently resolves
# to; the build verifies the two match so a tag mutation is caught immediately.
# hadolint ignore=DL3059
RUN git clone --depth 1 --branch "${MARKDOWN_LINTER_FIXER_REF}" \
        https://github.com/s2005/markdown-linter-fixer-skill.git /opt/markdown-linter-fixer \
    && test "$(git -C /opt/markdown-linter-fixer rev-parse HEAD)" = "${MARKDOWN_LINTER_FIXER_COMMIT}" \
    && chown -R root:root /opt/markdown-linter-fixer

# ---- /opt/pre-commit (global pre-commit config) ------------------------------
# Cloned read-only into the image. After cloning, the .git directory is
# deleted and provenance is recorded in /opt/pre-commit/.env (SHA=<sha>).
# Hard build-time assertion: if upstream ever renames or removes the
# config file the build fails right here.
# Owned by root so the unprivileged `developer` user can read + execute but
# cannot modify anything in here.
# CREDFETO_PRECOMMIT_CACHE_BUST is updated daily by the build workflow to ensure
# the latest hook config is always pulled in. CREDFETO_PRECOMMIT_COMMIT records
# the expected HEAD SHA and is updated alongside CACHE_BUST; the build fails if
# the two diverge, catching any unexpected upstream change between daily runs.
# hadolint ignore=DL3059
RUN : "${CREDFETO_PRECOMMIT_CACHE_BUST}"; \
    git clone --depth 1 "$PRECOMMIT_UPSTREAM" /opt/pre-commit \
    && test "$(git -C /opt/pre-commit rev-parse HEAD)" = "${CREDFETO_PRECOMMIT_COMMIT}" \
    && test -f /opt/pre-commit/src/.pre-commit-config.yaml \
    && HEAD_SHA="$(git -C /opt/pre-commit rev-parse HEAD)" \
    && rm -rf /opt/pre-commit/.git \
              /opt/pre-commit/.github \
              /opt/pre-commit/.ai-instructions \
              /opt/pre-commit/ai \
              /opt/pre-commit/CLAUDE.md \
    && printf 'SHA=%s\n' "$HEAD_SHA" > /opt/pre-commit/.env \
    && chown -R root:root /opt/pre-commit

# Global hooks directory referenced by core.hooksPath. The shim execs the
# upstream credfeto orchestrator (hooks/pre-commit), which is the entry
# point that runs the full chain. Owned by root for the same reason as the
# clone above. Explicit chmod on the orchestrator is belt-and-braces in
# case upstream loses the +x bit.
# hadolint ignore=DL3059
RUN mkdir -p /opt/git-global-hooks \
    && chmod 0755 /opt/pre-commit/src/hooks/pre-commit \
    && printf '#!/bin/bash\nexec /opt/pre-commit/src/hooks/pre-commit "$@"\n' \
        > /opt/git-global-hooks/pre-commit \
    && chmod 0755 /opt/git-global-hooks/pre-commit \
    && chown -R root:root /opt/git-global-hooks

# Scripts in /opt/pre-commit/src/scripts/ (e.g. run-bats) must be on PATH so
# pre-commit hook entries that reference them by name resolve correctly.
ENV PATH="/opt/pre-commit/src/scripts:${PATH}"

# ---- System-wide gitconfig (tamper-resistant) --------------------------------
# Baked in at /etc/gitconfig as root:root mode 0444. The unprivileged
# `developer` user the agent runs as has no way to modify it.
# Build context must be repo root so this COPY path resolves correctly.
COPY system-gitconfig /etc/gitconfig
RUN chown root:root /etc/gitconfig \
    && chmod 0444 /etc/gitconfig \
    && git config --file /etc/gitconfig --list >/dev/null

# gpg2 symlink — Debian's convention; gitconfigs that pin gpg.program=/usr/bin/gpg2
# work without an env override.
# hadolint ignore=DL3059
RUN ln -sf /usr/bin/gpg /usr/bin/gpg2

# ---- Build-time sanity check ------------------------------------------------
# Fails the build (not the agent at runtime) if any required binary is missing,
# HTTPS git clone is broken, dotnet tools are absent, or the pre-commit
# hook wiring is incorrect.
# hadolint ignore=DL3059
RUN set -e; \
    echo "== binary presence + version probe (stage 1+2+3 inherited binaries) =="; \
    for cmd in git gh dotnet python3 gpg curl jq sqlite3 \
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
    echo "== claude-code check (apt-installed in this stage) =="; \
    if ! command -v claude >/dev/null 2>&1; then \
        echo "FATAL sanity: required binary 'claude' is missing" >&2; exit 1; \
    fi; \
    claude --version >/dev/null 2>&1 || claude --help >/dev/null 2>&1 \
        || { echo "FATAL sanity: 'claude' is not functional" >&2; exit 1; }; \
    echo "== dotnet tools =="; \
    for tool in credfeto.changelog.cmd credfeto.dotnet.code.analysis.overrides.cmd tsqllint funfair.buildcheck funfair.buildversion cwm.roslynnavigator dotnet-ef ilspycmd microsoft.sqlpackage powershell credfeto.dotnet.repo.formatter dotnet-script; do \
        if ! su developer -c "dotnet tool list -g" | awk '{print tolower($1)}' | grep -Fxq "$tool"; then \
            echo "FATAL sanity: dotnet tool '$tool' is missing" >&2; exit 1; \
        fi; \
    done; \
    echo "== cwm-roslyn-navigator functional probe =="; \
    su developer -c "cwm-roslyn-navigator --help >/dev/null 2>&1" \
        || { echo "FATAL sanity: cwm-roslyn-navigator --help did not exit 0" >&2; exit 1; }; \
    echo "== gpg + sqlite3 self-check =="; \
    echo "probe" | gpg --dearmor >/dev/null 2>&1 || gpg --version >/dev/null; \
    sqlite3 :memory: "SELECT 1;" | grep -q 1; \
    echo "== HTTPS clone (dnyw4l3n13/scratch — sacrificial sanity target) =="; \
    rm -rf /tmp/sanity-clone; \
    GIT_CONFIG_SYSTEM=/dev/null git clone --depth 1 https://github.com/dnyw4l3n13/scratch.git /tmp/sanity-clone; \
    test -d /tmp/sanity-clone/.git; \
    rm -rf /tmp/sanity-clone; \
    echo "== pre-commit wiring checks =="; \
    test -f /opt/pre-commit/.env \
        || { echo "FATAL sanity: /opt/pre-commit/.env is missing" >&2; exit 1; }; \
    test -f /opt/pre-commit/src/.pre-commit-config.yaml \
        || { echo "FATAL sanity: /opt/pre-commit/src/.pre-commit-config.yaml is missing" >&2; exit 1; }; \
    test -x /opt/git-global-hooks/pre-commit \
        || { echo "FATAL sanity: /opt/git-global-hooks/pre-commit is not executable" >&2; exit 1; }; \
    command -v run-bats >/dev/null 2>&1 \
        || { echo "FATAL sanity: run-bats not on PATH — /opt/pre-commit/src/scripts/ missing from PATH?" >&2; exit 1; }; \
    echo "== all build-time checks passed =="

# ---- /opt/pre-commit acceptance suite (end-to-end hook orchestrator test) ---
# Run the upstream credfeto acceptance script against the installed hook
# chain. Placed after the sanity check so all tooling is verified first.
# Copy to /tmp and run as developer (tools are installed in developer's
# per-user profile); strip .env from the copy so the orchestrator's
# network-dependent freshness check is silently skipped for non-freshness tests.
# hadolint ignore=DL3059
RUN set -e; \
    cp -a /opt/pre-commit /tmp/pre-commit-test; \
    rm -f /tmp/pre-commit-test/.env; \
    chown -R developer:developer /tmp/pre-commit-test; \
    su developer -c /tmp/pre-commit-test/acceptance-test; \
    rm -rf /tmp/pre-commit-test
