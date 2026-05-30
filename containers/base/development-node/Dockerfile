# syntax=docker/dockerfile:1.7
# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-tools:latest

# ---- Build-time arguments ----------------------------------------------------
ARG BUN_VERSION=1.3.13
ARG CLAUDE_CODE_VERSION=latest
ARG MARKDOWNLINT_CLI2_VERSION=latest
ARG MARKDOWNLINT_CLI_VERSION=latest
ARG STYLELINT_VERSION=latest
ARG STYLELINT_CONFIG_STANDARD_VERSION=latest
ARG ESLINT_VERSION=latest
ARG BLOCK_NO_VERIFY_VERSION=1.1.5

# ---- npm registry (private mirror) ------------------------------------------
# Routes both build-time and runtime npm installs through the local cache
# mirror at npm.markridgwell.com. /etc/npmrc is root:root mode 0444 so
# unprivileged users can read but not replace it.
# NPM_CONFIG_REGISTRY env covers any tooling that does its own env probe.
RUN echo "registry=https://npm.markridgwell.com/" > /etc/npmrc \
    && chown root:root /etc/npmrc \
    && chmod 0444 /etc/npmrc
ENV NPM_CONFIG_REGISTRY=https://npm.markridgwell.com/

# Enable pipefail so any pipe error is caught.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Node.js v24.x via NodeSource -------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---- Bun runtime -------------------------------------------------------------
# Install via the official script (handles multi-arch detection), then move
# the binary to /usr/local/bin so every user can execute it.
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}" \
    && install -m 0755 /root/.bun/bin/bun /usr/local/bin/bun \
    && rm -rf /root/.bun

# ---- npm global installs (most stable first, most frequently bumped last) ----
# claude-code: postinstall downloads the native binary — works fine with npm.
# markdownlint-cli2: companion CLI for the markdown-linter-fixer-skill kit.
# markdownlint-cli, stylelint + standard config, eslint: additional linters
#   the agent reaches for when a project doesn't ship its own.
# block-no-verify: security guard that blocks `git --no-verify` and
#   core.hooksPath overrides.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm install -g "markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}" \
    && npm install -g \
        "markdownlint-cli@${MARKDOWNLINT_CLI_VERSION}" \
        "stylelint@${STYLELINT_VERSION}" \
        "stylelint-config-standard@${STYLELINT_CONFIG_STANDARD_VERSION}" \
        "eslint@${ESLINT_VERSION}" \
    && npm install -g "block-no-verify@${BLOCK_NO_VERIFY_VERSION}"

# ---- Build-time sanity check ------------------------------------------------
RUN set -e; \
    echo "== stage 1 binary presence check =="; \
    for cmd in git gh dotnet curl; do \
        if ! command -v "$cmd" >/dev/null 2>&1; then \
            echo "FATAL sanity: required stage-1 binary '$cmd' is missing" >&2; exit 1; \
        fi; \
    done; \
    echo "== stage 2 binary version probe =="; \
    node --version; \
    bun --version; \
    claude --version >/dev/null 2>&1 || claude --help >/dev/null 2>&1; \
    markdownlint-cli2 --version; \
    markdownlint --version; \
    stylelint --version; \
    eslint --version; \
    if ! command -v block-no-verify >/dev/null 2>&1; then \
        echo "FATAL sanity: block-no-verify is not on PATH" >&2; exit 1; \
    fi; \
    echo "== all build-time checks passed =="
