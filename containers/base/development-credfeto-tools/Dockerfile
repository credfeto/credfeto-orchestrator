# syntax=docker/dockerfile:1.7
# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-dotnet-tools:latest

# Use bash with pipefail for all subsequent RUN instructions so that pipes
# fail the step on any non-zero exit in the pipeline, not just the last command.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Build-time arguments ----------------------------------------------------
# Resolved by build-development-credfeto-tools.yml via the nuget-latest-versions
# composite action — a hash of the latest published version of every tool this
# image installs, so the layers below only re-run when one of them actually
# ships a new release (not on a blind daily schedule).
ARG CREDFETO_FUNFAIR_TOOLS_CACHE_BUST

# NuGet.Config, NUGET_PACKAGES, and claude-code are already baked in by
# development-dotnet-tools (this image's base) — nothing to redo here.

# ---- .NET global tools: first-party Credfeto.*/FunFair.* packages ------------
# These are org-owned packages this project actively ships (see
# containers/base/development-dotnet-tools for the genuinely third-party ones,
# which get their own image and their own freshness-check cadence so a
# release of one set never busts the other).
#
# Each tool gets its own RUN so:
#   - per-blob layer size stays modest (any one tool fits well under
#     typical registry edge body-size caps like Cloudflare's 100 MB).
#   - failure on one tool doesn't blow away the cache for the others.
# `: ${CREDFETO_FUNFAIR_TOOLS_CACHE_BUST}` substitutes the ARG into the command
# text (no-op shell `:` discards it) so the buildkit cache key for every layer
# includes the cache-bust value — the layers re-install in lockstep when the
# ARG changes (i.e. when any one of these tools ships a new version).
RUN su developer -c ": ${CREDFETO_FUNFAIR_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.Changelog.Cmd"
# hadolint ignore=DL3059
RUN su developer -c ": ${CREDFETO_FUNFAIR_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.DotNet.Code.Analysis.Overrides.Cmd"
# hadolint ignore=DL3059
RUN su developer -c ": ${CREDFETO_FUNFAIR_TOOLS_CACHE_BUST}; dotnet tool install -g FunFair.BuildCheck"
# hadolint ignore=DL3059
RUN su developer -c ": ${CREDFETO_FUNFAIR_TOOLS_CACHE_BUST}; dotnet tool install -g FunFair.BuildVersion"
# hadolint ignore=DL3059
RUN su developer -c ": ${CREDFETO_FUNFAIR_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.DotNet.Repo.Formatter"

# dotnet- subcommand aliases. Several tools install only as `<name>` but
# agents invoke them via `dotnet <name>` subcommand syntax — which makes
# the dotnet CLI look for `dotnet-<name>` on PATH. Without the alias the
# call fails with "Could not execute because the specified command or
# file was not found". Bake them into the image. Idempotent: ln -sf overwrites.
# hadolint ignore=DL3059
RUN su developer -c '\
    ln -sf cscleanup     /home/developer/.dotnet/tools/dotnet-cscleanup && \
    ln -sf buildcheck    /home/developer/.dotnet/tools/dotnet-buildcheck && \
    ln -sf buildversion  /home/developer/.dotnet/tools/dotnet-buildversion && \
    ln -sf changelog     /home/developer/.dotnet/tools/dotnet-changelog && \
    ln -sf code-analysis /home/developer/.dotnet/tools/dotnet-code-analysis'

# ---- Build-time sanity check ------------------------------------------------
# Fails the build (not the agent at runtime) if any tool this image installs
# is missing — fails fast at this layer instead of surfacing two images
# downstream in development-full's full-stack check.
# hadolint ignore=DL3059
RUN set -e; \
    echo "== dotnet tools =="; \
    for tool in credfeto.changelog.cmd credfeto.dotnet.code.analysis.overrides.cmd funfair.buildcheck funfair.buildversion credfeto.dotnet.repo.formatter; do \
        if ! su developer -c "dotnet tool list -g" | awk '{print tolower($1)}' | grep -Fxq "$tool"; then \
            echo "FATAL sanity: dotnet tool '$tool' is missing" >&2; exit 1; \
        fi; \
    done; \
    echo "== dotnet-* alias probe =="; \
    for alias in dotnet-cscleanup dotnet-buildcheck dotnet-buildversion dotnet-changelog dotnet-code-analysis; do \
        su developer -c "command -v ${alias} >/dev/null 2>&1" \
            || { echo "FATAL sanity: alias '${alias}' is missing from PATH" >&2; exit 1; }; \
    done; \
    echo "== all build-time checks passed =="
