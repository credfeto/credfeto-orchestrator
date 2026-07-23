# syntax=docker/dockerfile:1.7
# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-tools:latest

# ---- Build-time arguments ----------------------------------------------------
# Pin CLI/runtime versions for reproducibility. Bump deliberately — unpinned
# installs silently pick up the latest and can break in lockstep across all
# users (same policy as containers/base/development-tools/Dockerfile).
ARG NODE_MAJOR=24
ARG NODESOURCE_GPG_KEY_SHA256=b42e0321dabdc24e892115da705cf061167eac12a317f23d329862d0aa0a271d
ARG BUN_VERSION=1.3.13
ARG BUN_SHA256_AMD64=79c0771fa8b92c33aae41e15a0e0d307ea99d0e2f00317c71c6c53237a78e25a
ARG BUN_SHA256_ARM64=70bae41b3908b0a120e1e58c5c8af30e74afae3b8d11b0d3fdd8e787ddfb4b22
ARG MARKDOWNLINT_CLI2_VERSION=0.23.1
ARG MARKDOWNLINT_CLI_VERSION=0.49.1
ARG STYLELINT_VERSION=17.14.1
ARG STYLELINT_CONFIG_STANDARD_VERSION=40.0.0
ARG ESLINT_VERSION=10.7.0
ARG BLOCK_NO_VERIFY_VERSION=1.1.5

# Use bash with pipefail for all subsequent RUN instructions so that pipes
# fail the step on any non-zero exit in the pipeline, not just the last command.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- npm registry (private mirror) ------------------------------------------
# Routes both build-time and runtime npm installs through the local cache
# mirror at npm.markridgwell.com. /etc/npmrc is root:root mode 0444 so
# unprivileged users can read but not replace it.
# NPM_CONFIG_REGISTRY env covers any tooling that does its own env probe.
RUN echo "registry=https://npm.markridgwell.com/" > /etc/npmrc \
    && chown root:root /etc/npmrc \
    && chmod 0444 /etc/npmrc
ENV NPM_CONFIG_REGISTRY=https://npm.markridgwell.com/

# ---- Node.js via NodeSource --------------------------------------------------
# The NodeSource apt repository is configured directly (mirroring what
# setup_24.x itself does) instead of piping that script to bash — avoids
# executing remotely-fetched code without integrity verification. The signing
# key is checked against a pinned SHA256 before being dearmored into a keyring
# that apt then verifies the repo's Release file against.
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.key \
    && echo "${NODESOURCE_GPG_KEY_SHA256}  /tmp/nodesource.key" | sha256sum -c - \
    && gpg --dearmor -o /usr/share/keyrings/nodesource.gpg /tmp/nodesource.key \
    && chmod 0644 /usr/share/keyrings/nodesource.gpg \
    && rm /tmp/nodesource.key \
    && printf 'Types: deb\nURIs: https://deb.nodesource.com/node_%s.x\nSuites: nodistro\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/keyrings/nodesource.gpg\n' \
        "${NODE_MAJOR}" "${ARCH}" > /etc/apt/sources.list.d/nodesource.sources \
    && printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' \
        > /etc/apt/preferences.d/nodejs \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---- Bun runtime -------------------------------------------------------------
# Static release archive; downloaded directly from GitHub releases and
# verified against the pinned SHA256 checksum, replacing the official
# bun.sh/install script to avoid executing remotely-fetched code without
# integrity verification.
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) BUN_ARCH=x64;     SHA256="${BUN_SHA256_AMD64}" ;; \
         arm64) BUN_ARCH=aarch64; SHA256="${BUN_SHA256_ARM64}" ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL \
        "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${BUN_ARCH}.zip" \
        -o /tmp/bun.zip \
    && echo "${SHA256}  /tmp/bun.zip" | sha256sum -c - \
    && unzip -q /tmp/bun.zip -d /tmp/bun-extract \
    && install -m 0755 "/tmp/bun-extract/bun-linux-${BUN_ARCH}/bun" /usr/local/bin/bun \
    && rm -rf /tmp/bun.zip /tmp/bun-extract

# ---- npm global installs (most stable first, most frequently bumped last) ----
# markdownlint-cli2: companion CLI for the markdown-linter-fixer-skill kit.
# markdownlint-cli, stylelint + standard config, eslint: additional linters
#   the agent reaches for when a project doesn't ship its own.
# block-no-verify: security guard that blocks `git --no-verify` and
#   core.hooksPath overrides.
# Note: claude-code is installed via apt in development-full — it changes more
# frequently than Node/npm globals and benefits from a dedicated apt source.
RUN npm install -g "markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}" \
    && npm install -g \
        "markdownlint-cli@${MARKDOWNLINT_CLI_VERSION}" \
        "stylelint@${STYLELINT_VERSION}" \
        "stylelint-config-standard@${STYLELINT_CONFIG_STANDARD_VERSION}" \
        "eslint@${ESLINT_VERSION}" \
    && npm install -g "block-no-verify@${BLOCK_NO_VERIFY_VERSION}"

# ---- Build-time sanity check ------------------------------------------------
# hadolint ignore=DL3001
RUN set -e; \
    echo "== stage 1 + stage 2 binary presence + version probe =="; \
    for cmd in git gpg curl dotnet shellcheck shfmt bats sqlite3 gh \
               hadolint dotenv-linter sqlcmd actionlint trufflehog \
               python3 ansible-lint flake8 pylint \
               yamllint pre-commit xmllint; do \
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
    echo "== stage 2 binary version probe =="; \
    node --version; \
    bun --version; \
    markdownlint-cli2 --version; \
    markdownlint --version; \
    stylelint --version; \
    eslint --version; \
    if ! command -v block-no-verify >/dev/null 2>&1; then \
        echo "FATAL sanity: block-no-verify is not on PATH" >&2; exit 1; \
    fi; \
    echo "== ssh version check (uses -V not --version) =="; \
    if ! ssh -V >/dev/null 2>&1; then \
        echo "FATAL sanity: ssh -V did not exit 0" >&2; exit 1; \
    fi; \
    echo "== HTTPS clone (dnyw4l3n13/scratch — sacrificial sanity target) =="; \
    rm -rf /tmp/sanity-clone-node; \
    GIT_CONFIG_SYSTEM=/dev/null git clone --depth 1 \
        https://github.com/dnyw4l3n13/scratch.git /tmp/sanity-clone-node; \
    rm -rf /tmp/sanity-clone-node; \
    echo "== all build-time checks passed =="

# Bake the git SHA of the orchestrator commit that built this image layer into the
# environment so entrypoint.sh can log it for debugging. Placed last so changing
# the SHA only invalidates this cheap final layer.
ARG BUILD_GIT_SHA=unknown
ENV IMAGE_SHA_DEVELOPMENT_NODE=${BUILD_GIT_SHA}
