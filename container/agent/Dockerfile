# syntax=docker/dockerfile:1.7
# NanoClaw Agent CUSTOMISATION layer.
#
# This is the thin half of the agent container split. It just adds the
# entrypoint scripts, workspace setup, and ENTRYPOINT on top of the base
# image (which contains apt + bun + dotnet + pnpm globals + every static
# binary + sanity check — see container/base.Dockerfile).
#
# Why split: the base takes ~20 minutes to build cold. The customisation
# rebuilds in seconds. Iterating on entrypoint.sh / startup-check.sh used
# to invalidate the entire downstream chain; now it only invalidates these
# few directives.
#
# The base is built and pushed nightly by .github/workflows/build-base-image.yml.
# Local builds pull it from the registry. To force a local base rebuild
# (e.g. when iterating on base.Dockerfile or enabling INSTALL_CJK_FONTS),
# run ./container/build-base.sh.
ARG BASE_REPO=ghcr.io/dnyw4l3n13/nanoclaw-base
ARG BASE_TAG=latest
FROM ${BASE_REPO}:${BASE_TAG}

# Explicit USER root so this layer works against any base regardless of
# whether the base ended with USER node or as root. The base.Dockerfile in
# this repo ends as root, but pinning here is cheap and makes the layer
# composable against any drop-in base image.
USER root

# ---- Entrypoint + startup self-test -----------------------------------------
COPY entrypoint.sh     /app/entrypoint.sh
COPY startup-check.sh  /app/startup-check.sh
# chmod 755 (not just +x) so the unprivileged `node` user can both read and
# execute. `+x` on a file with no `r` for other = exit 126 ("permission
# denied") because the kernel can't load the script's shebang line.
RUN chmod 755 /app/entrypoint.sh /app/startup-check.sh

# ---- Workspace + permissions ------------------------------------------------
RUN mkdir -p /workspace/group /workspace/extra && \
    chown -R node:node /workspace && \
    chmod 777 /home/node

# ---- Login-shell PATH augmentation ------------------------------------------
# Dockerfile's ENV PATH=...:/home/node/.dotnet/tools propagates to processes
# spawned by the entrypoint, but anything that runs through /etc/profile
# (login shells, husky's `bash --login`, some pre-commit invocations, sshd
# sessions) rebuilds PATH from scratch via /etc/login.defs ENV_PATH. That
# wipes /home/node/.dotnet/tools and /pnpm — making every dotnet tool and
# every pnpm-global Node CLI invisible exactly when the agent's own pre-
# commit hook tries to run cscleanup / buildcheck. Drop a profile.d snippet
# that re-augments PATH for login shells. Idempotent — sourced after each
# login, so it doesn't compound on re-source.
RUN printf '%s\n' \
    'case ":$PATH:" in *":/home/node/.dotnet/tools:"*) ;; *) PATH="$PATH:/home/node/.dotnet/tools" ;; esac' \
    'case ":$PATH:" in *":/pnpm:"*) ;; *) PATH="/pnpm:$PATH" ;; esac' \
    'export PATH' \
    > /etc/profile.d/nanoclaw-paths.sh \
    && chmod 644 /etc/profile.d/nanoclaw-paths.sh

# ---- dotnet- subcommand aliases ---------------------------------------------
# Several dotnet global tools install only as `<name>` (cscleanup, buildcheck,
# buildversion, changelog, code-analysis, cwm-roslyn-navigator, tsqllint),
# but agents and pre-commit hooks invoke them via the `dotnet <name>`
# subcommand syntax — which makes the dotnet CLI look for `dotnet-<name>`
# on PATH. Without the alias the call fails with "Could not execute because
# the specified command or file was not found." and the agent (correctly)
# diagnoses it as a missing tool. Bake the aliases at image build time so
# they're present before any process starts. cscleanup ships with
# Credfeto.DotNet.Repo.Formatter (the replacement for CSharpier).
RUN su node -c '\
    ln -sf cscleanup             /home/node/.dotnet/tools/dotnet-cscleanup && \
    ln -sf buildcheck            /home/node/.dotnet/tools/dotnet-buildcheck && \
    ln -sf buildversion          /home/node/.dotnet/tools/dotnet-buildversion && \
    ln -sf changelog             /home/node/.dotnet/tools/dotnet-changelog && \
    ln -sf code-analysis         /home/node/.dotnet/tools/dotnet-code-analysis && \
    ln -sf cwm-roslyn-navigator  /home/node/.dotnet/tools/dotnet-cwm-roslyn-navigator && \
    ln -sf ilspycmd              /home/node/.dotnet/tools/dotnet-ilspycmd && \
    ln -sf sqlpackage            /home/node/.dotnet/tools/dotnet-sqlpackage && \
    ln -sf tsqllint              /home/node/.dotnet/tools/dotnet-tsqllint'

USER node
WORKDIR /workspace/group

# tini is PID 1, reaps zombies, forwards signals cleanly. entrypoint.sh does
# `exec bun ...` so bun runs as tini's direct child.
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
