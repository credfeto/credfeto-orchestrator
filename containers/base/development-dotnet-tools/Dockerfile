# syntax=docker/dockerfile:1.7
# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-python:latest

# Use bash with pipefail for all subsequent RUN instructions so that pipes
# fail the step on any non-zero exit in the pipeline, not just the last command.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Build-time arguments ----------------------------------------------------
# Resolved by build-development-dotnet-tools.yml via the nuget-latest-versions
# composite action — a hash of the latest published version of every tool this
# image installs, so the layers below only re-run when one of them actually
# ships a new release (not on a blind daily schedule).
ARG STABLE_TOOLS_CACHE_BUST

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
# were added in development-tools. STABLE_TOOLS_CACHE_BUST busts this layer
# whenever the NuGet freshness check below detects any tool has a new release,
# ensuring claude-code is refreshed on the same cadence.
# hadolint ignore=DL3027,DL3059
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    : "${STABLE_TOOLS_CACHE_BUST}"; \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        claude-code \
    && rm -rf /var/lib/apt/lists/*

# ---- .NET global tools: stable third-party packages --------------------------
# These are genuinely third-party/external tools with no credfeto/funfair
# ownership (see containers/base/development-credfeto-tools for the org-owned
# ones, which get their own image and their own freshness-check cadence so a
# release of one set never busts the other).
#
# Each tool gets its own RUN so:
#   - per-blob layer size stays modest (any one tool fits well under
#     typical registry edge body-size caps like Cloudflare's 100 MB).
#   - failure on one tool doesn't blow away the cache for the others.
# `: ${STABLE_TOOLS_CACHE_BUST}` substitutes the ARG into the command text
# (no-op shell `:` discards it) so the buildkit cache key for every layer
# includes the cache-bust value — the layers re-install in lockstep when the
# ARG changes (i.e. when any one of these tools ships a new version).
RUN su developer -c ": ${STABLE_TOOLS_CACHE_BUST}; dotnet tool install -g TSQLLint"
# hadolint ignore=DL3059
RUN su developer -c ": ${STABLE_TOOLS_CACHE_BUST}; dotnet tool install -g CWM.RoslynNavigator"
# hadolint ignore=DL3059
RUN su developer -c ": ${STABLE_TOOLS_CACHE_BUST}; dotnet tool install -g dotnet-ef"
# hadolint ignore=DL3059
RUN su developer -c ": ${STABLE_TOOLS_CACHE_BUST}; dotnet tool install -g ilspycmd"
# hadolint ignore=DL3059
RUN su developer -c ": ${STABLE_TOOLS_CACHE_BUST}; dotnet tool install -g Microsoft.SqlPackage"
# hadolint ignore=DL3059
RUN su developer -c ": ${STABLE_TOOLS_CACHE_BUST}; dotnet tool install -g PowerShell"
# hadolint ignore=DL3059
RUN su developer -c ": ${STABLE_TOOLS_CACHE_BUST}; dotnet tool install -g dotnet-script"

# dotnet- subcommand aliases. Several tools install only as `<name>` but
# agents invoke them via `dotnet <name>` subcommand syntax — which makes
# the dotnet CLI look for `dotnet-<name>` on PATH. Without the alias the
# call fails with "Could not execute because the specified command or
# file was not found". Bake them into the image. Idempotent: ln -sf overwrites.
# hadolint ignore=DL3059
RUN su developer -c '\
    ln -sf cwm-roslyn-navigator  /home/developer/.dotnet/tools/dotnet-cwm-roslyn-navigator && \
    ln -sf ilspycmd              /home/developer/.dotnet/tools/dotnet-ilspycmd && \
    ln -sf sqlpackage            /home/developer/.dotnet/tools/dotnet-sqlpackage && \
    ln -sf tsqllint              /home/developer/.dotnet/tools/dotnet-tsqllint && \
    ln -sf pwsh                  /home/developer/.dotnet/tools/dotnet-pwsh'

# PSScriptAnalyzer PowerShell module — check-setup (in development-full)
# imports it (`dotnet pwsh -Command "Import-Module PSScriptAnalyzer ..."`) to
# validate the VALIDATE_POWERSHELL hook, so it must be present for the
# developer user in addition to the pwsh binary/alias above. Installed via
# Install-PSResource (Microsoft.PowerShell.PSResourceGet, bundled with pwsh
# 7.4+) rather than the legacy Install-Module: the latter needs the old
# PackageManagement "NuGet" provider bootstrapped first, which fails
# non-interactively here ("No match was found for the specified search
# criteria for the provider 'NuGet'") even though the PSGallery endpoint
# itself is reachable. PSResourceGet talks to the gallery directly and needs
# no such bootstrap.
# hadolint ignore=DL3059
RUN su developer -c 'dotnet pwsh -NoProfile -NonInteractive -Command \
    "Install-PSResource -Name PSScriptAnalyzer -Scope CurrentUser -TrustRepository -ErrorAction Stop"'

# ---- Build-time sanity check ------------------------------------------------
# Fails the build (not the agent at runtime) if claude-code or any tool this
# image installs is missing — fails fast at this layer instead of surfacing
# three images downstream in development-full's full-stack check.
# hadolint ignore=DL3059
RUN set -e; \
    echo "== claude-code check (apt-installed in this stage) =="; \
    if ! command -v claude >/dev/null 2>&1; then \
        echo "FATAL sanity: required binary 'claude' is missing" >&2; exit 1; \
    fi; \
    claude --version >/dev/null 2>&1 || claude --help >/dev/null 2>&1 \
        || { echo "FATAL sanity: 'claude' is not functional" >&2; exit 1; }; \
    echo "== dotnet tools =="; \
    for tool in tsqllint cwm.roslynnavigator dotnet-ef ilspycmd microsoft.sqlpackage powershell dotnet-script; do \
        if ! su developer -c "dotnet tool list -g" | awk '{print tolower($1)}' | grep -Fxq "$tool"; then \
            echo "FATAL sanity: dotnet tool '$tool' is missing" >&2; exit 1; \
        fi; \
    done; \
    echo "== cwm-roslyn-navigator functional probe =="; \
    su developer -c "cwm-roslyn-navigator --help >/dev/null 2>&1" \
        || { echo "FATAL sanity: cwm-roslyn-navigator --help did not exit 0" >&2; exit 1; }; \
    echo "== pwsh + PSScriptAnalyzer functional probe =="; \
    su developer -c 'dotnet pwsh -NoProfile -NonInteractive -Command "Import-Module PSScriptAnalyzer -ErrorAction Stop"' \
        || { echo "FATAL sanity: PSScriptAnalyzer module did not import" >&2; exit 1; }; \
    echo "== all build-time checks passed =="
