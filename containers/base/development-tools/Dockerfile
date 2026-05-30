# syntax=docker/dockerfile:1.7
# development-tools base image — CI/CD and linting toolchain, no entrypoint or
# workspace setup.
#
# This image packages the full suite of development and linting tools used by
# the credfeto orchestrator: static analysers, linters, the GitHub CLI, .NET
# SDK, and various language-specific tooling. It intentionally contains no
# application source, entrypoint scripts, or user workspace — those belong in
# the customisation layer that FROMs this image.
#
# Built and pushed hourly by .github/workflows/build-development-tools.yml as
#   ghcr.io/<owner>/development-tools:YYYY-MM-DD + :latest
#
# Multi-stage build: a throwaway Go stage compiles composite-action-lint (no
# published release binaries) so the final image doesn't carry the ~500 MB Go
# toolchain.

# ---- composite-action-lint builder (Go multi-stage) -------------------------
# bettermarks/composite-action-lint ships no GitHub releases — it's a Go CLI
# meant to be `go install`d. We build it once in a throwaway Go stage so the
# final image doesn't carry the ~500 MB Go toolchain. Pinned to upstream
# master with a daily/SHA cache-bust below; HEAD is captured for the .env.
ARG COMPOSITE_ACTION_LINT_UPSTREAM=https://github.com/bettermarks/composite-action-lint.git
ARG COMPOSITE_ACTION_LINT_REF=master
ARG COMPOSITE_ACTION_LINT_CACHE_BUST
FROM golang:1.24-bookworm AS composite-action-lint-builder
ARG COMPOSITE_ACTION_LINT_UPSTREAM
ARG COMPOSITE_ACTION_LINT_REF
ARG COMPOSITE_ACTION_LINT_CACHE_BUST
WORKDIR /src
RUN git clone --depth 1 --branch "$COMPOSITE_ACTION_LINT_REF" \
        "$COMPOSITE_ACTION_LINT_UPSTREAM" . \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
        -o /out/composite-action-lint ./cmd/composite-action-lint \
    && git rev-parse HEAD > /out/HEAD \
    && /out/composite-action-lint -h >/dev/null 2>&1 \
        || /out/composite-action-lint --help >/dev/null 2>&1 \
        || test -x /out/composite-action-lint

# ---- Final image -------------------------------------------------------------
FROM debian:trixie-slim

# Use bash with pipefail for all subsequent RUN instructions so that pipes
# fail the step on any non-zero exit in the pipeline, not just the last command.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Build-time arguments ----------------------------------------------------
# Pin CLI versions for reproducibility. Bump deliberately — unpinned installs
# silently pick up the latest and can break in lockstep across all users.
ARG HADOLINT_VERSION=v2.14.0
ARG DOTENV_LINTER_VERSION=v4.0.0
ARG SQLCMD_VERSION=v1.10.0
# actionlint: the download-actionlint.bash script resolves "latest" to the
# current release natively. Override via --build-arg ACTIONLINT_VERSION=vX.Y.Z
# to pin a specific release for reproducible builds.
ARG ACTIONLINT_VERSION=latest
# trufflehog: the upstream install.sh selects the current release when no
# version is given (empty ARG). Override via --build-arg TRUFFLEHOG_VERSION=vX.Y.Z.
ARG TRUFFLEHOG_VERSION
# composite-action-lint: built from source in the Go stage above. The
# UPSTREAM and CACHE_BUST ARGs are re-declared here so they can be baked into
# the .env provenance file alongside the HEAD SHA captured in the builder.
ARG COMPOSITE_ACTION_LINT_UPSTREAM=https://github.com/bettermarks/composite-action-lint.git
ARG COMPOSITE_ACTION_LINT_CACHE_BUST

# ---- Temporary directory -----------------------------------------------------
# Explicitly set TMPDIR so anything that does literal `mktemp -p "$TMPDIR"` or
# `cd "$TMPDIR"` works rather than failing on an empty expansion. /tmp is
# already drwxrwxrwt on the overlay so every user can write.
ENV TMPDIR=/tmp

# ---- Unprivileged user -------------------------------------------------------
# All tools run as root during the build; runtime consumers should switch to
# the `developer` user. Created here so downstream customisation layers and
# tool installers that need a real home directory under /home/developer can
# rely on its presence.
RUN useradd -m -s /bin/bash developer

# ---- System dependencies -----------------------------------------------------
# Debian contrib component: required for ttf-mscorefonts-installer, which
# downloads the real Microsoft TrueType core fonts (Arial, Times New Roman,
# Courier New, etc.) from SourceForge under their EULA. The EULA is preseeded
# via debconf so the install is fully non-interactive.
#
# Package notes:
#   tini       — correct PID 1 / signal forwarding
#   shfmt      — shell formatter
#   libicu76   — ICU Unicode library (required by .NET)
#   libxml2-utils — provides xmllint (used by the credfeto pre-commit chain)
#   fonts-liberation — metrically identical to Arial/Times/Courier; provides
#                      fontconfig aliases that headless Chrome, wkhtmltopdf,
#                      and weasyprint resolve automatically
#   ttf-mscorefonts-installer — real MS fonts needed by tools (e.g.
#                      SixLabors.Fonts) that match by internal family-name
#                      records rather than fontconfig aliases
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie\nComponents: contrib\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n' \
        > /etc/apt/sources.list.d/debian-contrib.sources \
    && echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
        | debconf-set-selections \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bats \
        ca-certificates \
        curl \
        dash \
        devscripts \
        git \
        gnupg \
        libicu76 \
        openssh-client \
        python3 \
        python3-pip \
        shellcheck \
        shfmt \
        sqlite3 \
        tini \
        unzip \
        ansible-lint \
        flake8 \
        fontconfig \
        fonts-liberation \
        ttf-mscorefonts-installer \
        libxml2-utils \
        pre-commit \
        pylint \
        yamllint \
    && fc-cache -f \
    && rm -rf /var/lib/apt/lists/*

# ---- GitHub CLI --------------------------------------------------------------
# Added via the upstream apt source so we track gh releases automatically
# (within the version range the keyring covers). The repo ships a signed
# Release file so no --allow-unauthenticated is needed.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Route gh CLI traffic through the local credfeto/github-api-proxy by default.
# The proxy validates a fake "proxy token" (held in OneCLI's vault), swaps
# it for the real GitHub PAT (which lives only in the proxy's .env), and
# forwards to api.github.com — blocking all git-write operations on the way.
# The real PAT NEVER enters this container.
#
# GH_ENTERPRISE_TOKEN is a sentinel placeholder. gh sends it in the
# Authorization header; OneCLI's egress middleware substitutes it for the
# actual fake-proxy-token before the request reaches the proxy. Any non-empty
# string works here — gh doesn't validate the token format upfront. The
# "ghp_PLACEHOLDER…" shape makes accidental leaks visually obvious as a
# placeholder rather than confused with a real PAT.
#
# Override per-spawn by exporting GH_HOST / GH_ENTERPRISE_TOKEN in the host
# env — those take precedence over these defaults.
ENV GH_HOST=github-api.markridgwell.com
ENV GH_ENTERPRISE_TOKEN=ghp_PLACEHOLDER_OneCLI_substitutes_this_at_egress

# ---- hadolint — Dockerfile linter -------------------------------------------
# Static binary; arch suffix differs (x86_64 / arm64). Downloaded from the
# GitHub releases page for the pinned HADOLINT_VERSION.
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) HL_ARCH=x86_64 ;; \
         arm64) HL_ARCH=arm64  ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-${HL_ARCH}" \
        -o /usr/local/bin/hadolint \
    && chmod 0755 /usr/local/bin/hadolint \
    && hadolint --version

# ---- dotenv-linter — .env file linter ----------------------------------------
# Static binary shipped as a .tar.gz archive. Arch suffix follows the dotenv-
# linter release naming convention (x86_64 / arm64).
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) DL_ARCH=x86_64 ;; \
         arm64) DL_ARCH=arm64  ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/dotenv-linter/dotenv-linter/releases/download/${DOTENV_LINTER_VERSION}/dotenv-linter-linux-${DL_ARCH}.tar.gz" \
        -o /tmp/dotenv-linter.tgz \
    && tar -xzf /tmp/dotenv-linter.tgz -C /usr/local/bin dotenv-linter \
    && chmod 0755 /usr/local/bin/dotenv-linter \
    && rm /tmp/dotenv-linter.tgz \
    && dotenv-linter --version

# ---- sqlcmd (microsoft/go-sqlcmd) — modern SQL Server CLI -------------------
# Static Go binary; replaces the legacy mssql-tools sqlcmd. Asset name is
# unversioned (sqlcmd-linux-<arch>.tar.bz2) — version comes from the URL path.
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) SC_ARCH=amd64 ;; \
         arm64) SC_ARCH=arm64 ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-${SC_ARCH}.tar.bz2" \
        -o /tmp/sqlcmd.tar.bz2 \
    && tar -xjf /tmp/sqlcmd.tar.bz2 -C /usr/local/bin sqlcmd \
    && chmod 0755 /usr/local/bin/sqlcmd \
    && rm /tmp/sqlcmd.tar.bz2 \
    && sqlcmd --version

# ---- actionlint — GitHub Actions workflow linter ----------------------------
# Static binary; the upstream installer script handles arch detection and
# downloads from the GitHub release page.
RUN curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash \
        -o /tmp/install-actionlint.sh \
    && bash /tmp/install-actionlint.sh "${ACTIONLINT_VERSION}" /usr/local/bin \
    && rm /tmp/install-actionlint.sh \
    && actionlint -version

# ---- trufflehog — secret scanner --------------------------------------------
# No Debian package available; upstream's install.sh handles arch detection
# and pulls a static binary from the GitHub release.
RUN curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
        | sh -s -- -b /usr/local/bin ${TRUFFLEHOG_VERSION:+"$TRUFFLEHOG_VERSION"} \
    && trufflehog --version

# ---- composite-action-lint --------------------------------------------------
# Built upstream-from-source by the multi-stage Go builder above (no release
# binaries are published). Lives at /opt/composite-action-lint/ alongside an
# .env recording HEAD + UPSTREAM (mirrors the /opt/pre-commit pattern: no .git
# anywhere, so an agent walking the FS can't `git pull` to update it).
# Symlinked into /usr/local/bin so it's on PATH like the other linters.
ARG COMPOSITE_ACTION_LINT_UPSTREAM
RUN mkdir -p /opt/composite-action-lint
COPY --from=composite-action-lint-builder /out/composite-action-lint /opt/composite-action-lint/composite-action-lint
COPY --from=composite-action-lint-builder /out/HEAD /tmp/composite-action-lint-head
RUN printf 'HEAD=%s\nUPSTREAM=%s\n' \
        "$(cat /tmp/composite-action-lint-head)" "$COMPOSITE_ACTION_LINT_UPSTREAM" \
        > /opt/composite-action-lint/.env \
    && rm /tmp/composite-action-lint-head \
    && chmod 0755 /opt/composite-action-lint/composite-action-lint \
    && ln -s /opt/composite-action-lint/composite-action-lint /usr/local/bin/composite-action-lint \
    && chown root:root /opt/composite-action-lint \
    && composite-action-lint -h >/dev/null 2>&1 \
        || composite-action-lint --help >/dev/null 2>&1 \
        || test -x /usr/local/bin/composite-action-lint

# ---- .NET SDK (LTS + STS side-by-side) ---------------------------------------
# Both channels installed because repos in this fork target multiple TFMs
# (e.g. net9.0 + net10.0). Without the STS channel, builds against net9.0
# fail with "framework not found" at restore/build time.
# dotnet tools are installed per-user into /home/developer/.dotnet/tools via
# `su developer -c "dotnet tool install -g ..."` so the developer user can
# invoke them without root. The PATH ENV below and the profile.d snippet
# ensure the tools directory is visible to login shells and non-login shells
# started by the entrypoint.
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel LTS --install-dir /usr/share/dotnet \
    && /tmp/dotnet-install.sh --channel STS --install-dir /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet \
    && rm /tmp/dotnet-install.sh

ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="${PATH}:/home/developer/.dotnet/tools"

# Login-shell PATH augmentation. The ENV PATH above propagates to processes
# spawned by the container entrypoint, but anything that runs through
# /etc/profile (login shells, husky's `bash --login`, some pre-commit
# invocations, sshd sessions) rebuilds PATH from scratch via
# /etc/login.defs ENV_PATH and wipes /home/developer/.dotnet/tools —
# making every dotnet tool invisible exactly when the pre-commit hook tries
# to run them. This profile.d snippet re-augments PATH for login shells.
# Idempotent (uses `case` guard so sourcing multiple times is harmless).
# hadolint ignore=SC2016
RUN { \
      echo 'case ":$PATH:" in *":/home/developer/.dotnet/tools:"*) ;; *) PATH="$PATH:/home/developer/.dotnet/tools" ;; esac'; \
      echo 'export PATH'; \
    } > /etc/profile.d/development-tools-paths.sh \
    && chmod 644 /etc/profile.d/development-tools-paths.sh

# ---- Build-time sanity check -------------------------------------------------
# Fails the build (not the consumer at runtime) if:
#   - any required binary is missing from PATH
#   - HTTPS git clone is broken (cert chain, network, proxy)
#   - ssh client can't report its version
# The SSH-auth and mount-dependent tests live at runtime in the consuming
# image's startup-check script (keys aren't available here at build time).
# hadolint ignore=DL3001
RUN set -e; \
    echo "== binary presence + version probe =="; \
    for cmd in git gpg curl dotnet shellcheck shfmt bats sqlite3 gh \
               hadolint dotenv-linter sqlcmd actionlint trufflehog \
               composite-action-lint python3 ansible-lint flake8 pylint \
               yamllint pre-commit xmllint; do \
        if ! command -v "$cmd" >/dev/null 2>&1; then \
            echo "FATAL sanity: required binary '$cmd' is missing" >&2; exit 1; \
        fi; \
        if ! "$cmd" --version >/dev/null 2>&1; then \
            echo "FATAL sanity: '$cmd --version' did not exit 0" >&2; exit 1; \
        fi; \
    done; \
    echo "== ssh version check (uses -V not --version) =="; \
    if ! ssh -V >/dev/null 2>&1; then \
        echo "FATAL sanity: ssh -V did not exit 0" >&2; exit 1; \
    fi; \
    echo "== HTTPS clone (dnyw4l3n13/scratch — sacrificial sanity target) =="; \
    rm -rf /tmp/sanity-clone1; \
    GIT_CONFIG_SYSTEM=/dev/null git clone --depth 1 \
        https://github.com/dnyw4l3n13/scratch.git /tmp/sanity-clone1; \
    rm -rf /tmp/sanity-clone1; \
    echo "== all build-time checks passed =="
