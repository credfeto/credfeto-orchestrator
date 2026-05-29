# syntax=docker/dockerfile:1.7
# NanoClaw Agent BASE image — packaged tools, no entrypoint or workspace setup.
#
# This is the heavy half of the agent container split. It contains everything
# that's stable across customer installs: apt packages, the Bun runtime,
# agent-runner runtime deps, pnpm globals, the .NET SDK + tools, all the
# upstream skill/plugin clones, every static binary download, and the
# build-time sanity check that asserts each tool is callable.
#
# It does NOT contain:
#   - /app/entrypoint.sh, /app/startup-check.sh  (project source — iterated on
#     frequently; baked into the thin customisation layer in container/Dockerfile)
#   - /workspace mkdir, USER node, WORKDIR, ENTRYPOINT  (customisation too)
#
# Built and pushed nightly by .github/workflows/build-base-image.yml as
#   docker-registry.markridgwell.com/credfeto/nanoclaw-base:YYYY-MM-DD + :latest
# The customisation Dockerfile FROMs this image; local rebuilds of the
# customisation layer pull the base from the registry rather than rebuilding
# the ~20-minute heavy half on every iteration.
#
# Runtime split:
#   - agent-runner (our TypeScript code): Bun, mounted RO at /app/src by host
#   - globally-installed Node CLIs (claude-code): pnpm + Node
#
# Source is never baked in — /app/src is provided by a shared read-only
# bind mount at runtime (see src/container-runner.ts). Source-only changes
# never require an image rebuild.

# ---- composite-action-lint builder (Go multi-stage) ------------------------
# bettermarks/composite-action-lint ships no GitHub releases — it's a Go CLI
# meant to be `go install`d. We build it once in a throwaway Go stage so the
# final image doesn't carry the ~500MB Go toolchain. Pinned to upstream
# master with daily cache-bust below; HEAD is captured for the .env.
ARG COMPOSITE_ACTION_LINT_UPSTREAM=https://github.com/bettermarks/composite-action-lint.git
ARG COMPOSITE_ACTION_LINT_REF=master
ARG COMPOSITE_ACTION_LINT_CACHE_BUST
FROM golang:1.24-bookworm AS composite-action-lint-builder
ARG COMPOSITE_ACTION_LINT_UPSTREAM
ARG COMPOSITE_ACTION_LINT_REF
ARG COMPOSITE_ACTION_LINT_CACHE_BUST
RUN git clone --depth 1 --branch "$COMPOSITE_ACTION_LINT_REF" \
        "$COMPOSITE_ACTION_LINT_UPSTREAM" /src \
    && cd /src \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
        -o /out/composite-action-lint ./cmd/composite-action-lint \
    && git -C /src rev-parse HEAD > /out/HEAD \
    && /out/composite-action-lint -h >/dev/null 2>&1 \
        || /out/composite-action-lint --help >/dev/null 2>&1 \
        || test -x /out/composite-action-lint

FROM node:22-trixie-slim

# ---- Build-time arguments ----------------------------------------------------
# CJK fonts add ~200MB. Opt in only if you render Chinese/Japanese/Korean text.
ARG INSTALL_CJK_FONTS=false

# Pin CLI versions for reproducibility. Bump deliberately — unpinned installs
# mean every rebuild silently picks up the latest and can break in lockstep
# across all users.
ARG CLAUDE_CODE_VERSION=2.1.123
ARG BUN_VERSION=1.3.13
ARG MARKDOWNLINT_CLI2_VERSION=latest
ARG MARKDOWNLINT_CLI_VERSION=latest
ARG STYLELINT_VERSION=latest
ARG STYLELINT_CONFIG_STANDARD_VERSION=latest
ARG ESLINT_VERSION=latest
ARG ACTIONLINT_VERSION=latest
ARG BLOCK_NO_VERIFY_VERSION=1.1.5
# Static-binary tools fetched from GitHub releases. Pinned because "latest"
# would silently bump on every rebuild.
ARG HADOLINT_VERSION=v2.14.0
ARG DOTENV_LINTER_VERSION=v4.0.0
ARG SQLCMD_VERSION=v1.10.0
# Trixie ships an old sqlfluff (3.3.1) — pinned-pip install gives us 4.x.
ARG SQLFLUFF_VERSION=4.1.0
# Pin the markdown skill to its current release tag — supply-chain surface
# is small (8★, single maintainer) so we don't track main here.
ARG MARKDOWN_LINTER_FIXER_REF=v1.5.4

# ---- System dependencies -----------------------------------------------------
# tini: correct PID 1 / signal forwarding so outbound.db writes finalize on
# SIGTERM instead of being orphaned by the shell entrypoint.
#
# Fonts:
#   - fonts-liberation — metrically-identical Liberation Sans/Serif/Mono. Wired
#     to Arial / Times / Courier via fontconfig's built-in aliases. Covers
#     any consumer that goes through fontconfig (headless Chrome/Chromium,
#     wkhtmltopdf, weasyprint, libgdiplus-backed .NET, etc.).
#   - ttf-mscorefonts-installer — the real Microsoft TrueType core fonts
#     (Arial, Times New Roman, Courier New, etc.) with the actual internal
#     family-name records that name-record-lookup font stacks require.
#     Specifically: SixLabors.Fonts (pure-managed .NET, used by ImageSharp
#     and downstream by funfair-discord-coinbot-server's PriceGraphBuilder)
#     does NOT use fontconfig — it scans font files and matches by the
#     family name record inside each file. Liberation Sans's record says
#     "Liberation Sans", so SystemFonts.Get("Arial") returns nothing without
#     real Arial. Lives in Debian's `contrib` component (added above as a
#     dedicated sources fragment) because the package downloads MS fonts
#     from SourceForge under their EULA. EULA preseeded via debconf so the
#     install is non-interactive. If SourceForge becomes unreliable, mirror
#     the .deb to npm.markridgwell.com.
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
    && if [ "$INSTALL_CJK_FONTS" = "true" ]; then \
        apt-get install -y --no-install-recommends fonts-noto-cjk; \
       fi \
    && fc-cache -f \
    && rm -rf /var/lib/apt/lists/*

# ---- npm registry (FunFair private mirror) ----------------------------------
# Routes BOTH build-time installs (root running pnpm/bun/npm install -g) and
# runtime agent installs (node user running npm/pnpm install) through the
# local cache mirror at npm.markridgwell.com.
#
# `npm config set registry ...` would only affect the user that ran it
# (writes to ~/.npmrc) — useless here because the build runs as root and
# the agent runs as node. Instead we bake `/etc/npmrc`, which npm and pnpm
# both read as the machine-wide global config regardless of invoking user.
# Owned root:root mode 0444 so the agent can't replace it (same tamper-
# resistance pattern as /etc/gitconfig and the locked-down NuGet config).
#
# `NPM_CONFIG_REGISTRY` env covers bun (which doesn't read /etc/npmrc) plus
# any oddball tooling that does its own env probe. Both layers point at the
# same URL so they can't diverge.
#
# Positioned BEFORE the Bun runtime install + agent-runner bun install +
# pnpm global installs below, so every subsequent package fetch uses the
# mirror. (The bun installer script itself fetches from bun.sh, not npm,
# so it's unaffected — it just runs.)
RUN echo "registry=https://npm.markridgwell.com/" > /etc/npmrc \
    && chown root:root /etc/npmrc \
    && chmod 0444 /etc/npmrc
ENV NPM_CONFIG_REGISTRY=https://npm.markridgwell.com/

# ---- TMPDIR ----------------------------------------------------------------
# Default TMPDIR explicitly so anything that does literal `mktemp -p "$TMPDIR"`
# or `cd "$TMPDIR"` works rather than failing on an empty expansion. /tmp is
# already drwxrwxrwt and on the overlay (so node can write), so nothing else
# has to change.
ENV TMPDIR=/tmp

# ---- Bun runtime -------------------------------------------------------------
# Install via the official script (handles multi-arch detection), then move
# the binary to /usr/local/bin so the non-root `node` user can execute it.
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}" && \
    install -m 0755 /root/.bun/bin/bun /usr/local/bin/bun && \
    rm -rf /root/.bun

# ---- agent-runner deps -------------------------------------------------------
# Deps are cached independently of CLI versions. Source is NOT baked in —
# it's provided by the shared RO mount at runtime.
WORKDIR /app

COPY agent-runner/package.json agent-runner/bun.lock ./

RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --frozen-lockfile

# ---- pnpm + global Node CLIs -------------------------------------------------
# Most stable first, most frequently bumped last. Bumping claude-code
# (the most common change) only invalidates one layer.
#
# only-built-dependencies gates pnpm's supply-chain policy:
#   - @anthropic-ai/claude-code's postinstall downloads the native Claude
#     binary (linux-arm64 variant on our image). Without the allowlist
#     the SDK fails at spawn time with "native binary not found".
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable

# Pin pnpm via corepack — pnpm 11.0.x silently broke two things at once:
#   1. dropped /etc/npmrc support, so the runtime registry mirror lookup
#      fell back to registry.npmjs.org regardless of npmrc / env config
#   2. tightened `pnpm install -g` to require PATH to contain $PNPM_HOME/bin
#      specifically (we set PNPM_HOME=/pnpm and PATH=/pnpm:..., which 10
#      accepted but 11 rejects with "configured global bin directory not in PATH")
# Both broke this image when corepack auto-bumped to 11.0.8 — production
# startup-check failed and the fresh build wouldn't finish step 9. Pin to
# 10.x as the stable behavior-set that still respects /etc/npmrc + the old
# global-install path layout.
#
# COREPACK_HOME=/opt/corepack puts the prepared binary in a system-wide
# location readable by every user; default is per-user (~/.cache/node/...)
# so a build-time prepare as root wouldn't reach the runtime `node` user
# and corepack would re-download "latest" on first invocation, defeating
# the pin AND adding a registry.npmjs.org round-trip per spawn.
ARG PNPM_VERSION=10.18.0
ENV COREPACK_HOME=/opt/corepack
RUN mkdir -p /opt/corepack && \
    corepack prepare pnpm@${PNPM_VERSION} --activate && \
    chmod -R a+rX /opt/corepack && \
    pnpm --version | grep -qFx "${PNPM_VERSION}"

RUN --mount=type=cache,target=/root/.cache/pnpm \
    echo "only-built-dependencies[]=@anthropic-ai/claude-code" > /root/.npmrc && \
    pnpm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# markdownlint-cli2 — companion CLI for the markdown-linter-fixer-skill kit.
RUN --mount=type=cache,target=/root/.cache/pnpm \
    pnpm install -g "markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}"

# Additional global linters: markdownlint (the original CLI, not cli2),
# stylelint + standard config, and eslint. The agent reaches for these when
# a project doesn't ship its own.
RUN --mount=type=cache,target=/root/.cache/pnpm \
    pnpm install -g \
        "markdownlint-cli@${MARKDOWNLINT_CLI_VERSION}" \
        "stylelint@${STYLELINT_VERSION}" \
        "stylelint-config-standard@${STYLELINT_CONFIG_STANDARD_VERSION}" \
        "eslint@${ESLINT_VERSION}"

# block-no-verify — security guard that blocks `git --no-verify`,
# `core.hooksPath` overrides, and GitHub MCP write-API calls. Wired into
# the agent-runner's PreToolUse hook chain (compiled, not config) so the
# agent CANNOT disable it. See container/agent-runner/src/providers/claude.ts.
RUN --mount=type=cache,target=/root/.cache/pnpm \
    pnpm install -g "block-no-verify@${BLOCK_NO_VERIFY_VERSION}"

# ---- GitHub CLI --------------------------------------------------------------
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
# actual fake-proxy-token before the request reaches the proxy. Any non-
# empty string works here — gh doesn't validate the token format upfront.
# The "ghp_PLACEHOLDER…" shape is just to make accidental leaks visually
# obvious as a placeholder rather than confused with a real PAT.
#
# Override per-spawn by exporting GH_HOST / GH_ENTERPRISE_TOKEN in the host
# env (see src/container-runner.ts) — those take precedence over these
# defaults. ~/.config/gh is intentionally NOT mounted (would leak the real
# PAT into the container).
ENV GH_HOST=github-api.markridgwell.com
ENV GH_ENTERPRISE_TOKEN=ghp_PLACEHOLDER_OneCLI_substitutes_this_at_egress

# ---- .NET SDK (LTS + STS side-by-side) ---------------------------------------
# Both channels installed because user repos in this fork target multiple
# TFMs (e.g. net9.0 + net10.0). Without the STS channel, builds against
# net9.0 fail with "framework not found" at restore/build time.
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel LTS --install-dir /usr/share/dotnet \
    && /tmp/dotnet-install.sh --channel STS --install-dir /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet \
    && rm /tmp/dotnet-install.sh

ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="${PATH}:/home/node/.dotnet/tools"

# Login-shell PATH augmentation. The ENV PATH above propagates to processes
# spawned by the container entrypoint, but anything that runs through
# /etc/profile (login shells, husky's `bash --login`, some pre-commit
# invocations, sshd sessions) rebuilds PATH from scratch via
# /etc/login.defs ENV_PATH and wipes /home/node/.dotnet/tools and /pnpm —
# making every dotnet tool and pnpm-global Node CLI invisible exactly when
# the agent's pre-commit hook tries to run cscleanup / buildcheck. This
# profile.d snippet re-augments PATH for login shells. Idempotent.
RUN printf '%s\n' \
    'case ":$PATH:" in *":/home/node/.dotnet/tools:"*) ;; *) PATH="$PATH:/home/node/.dotnet/tools" ;; esac' \
    'case ":$PATH:" in *":/pnpm:"*) ;; *) PATH="/pnpm:$PATH" ;; esac' \
    'export PATH' \
    > /etc/profile.d/nanoclaw-paths.sh \
    && chmod 644 /etc/profile.d/nanoclaw-paths.sh

# dotnet- subcommand aliases. Several tools install only as `<name>` but
# agents invoke them via `dotnet <name>` subcommand syntax — which makes
# the dotnet CLI look for `dotnet-<name>` on PATH. Without the alias the
# call fails with "Could not execute because the specified command or
# file was not found"; agents have historically had to `ln -sf` these
# themselves at runtime (which gets lost on every container restart).
# Bake them into the image. The dotnet tool installs run AFTER this point
# so we have to defer to a later RUN — see below "dotnet alias creation"
# placed after the `dotnet tool install -g` block.

# ---- NuGet package sources (FunFair private feeds) ---------------------------
# NuGet.Config is baked in root:root mode 0444 so the agent (running as the
# unprivileged `node` user) can read it but cannot modify, delete, or replace
# it in place. The full /home/node/.nuget/{,NuGet/} hierarchy is also root-
# owned 0755 — that prevents the agent from `rm`ing the locked-down NuGet
# subdir or swapping the file via a parent rename within .nuget itself.
#
# Because /home/node/.nuget is now root-owned, dotnet's default package
# cache at ~/.nuget/packages would not be writable. We redirect it to a
# node-owned sibling via NUGET_PACKAGES so `dotnet restore`, `dotnet tool
# install -g`, etc. continue to work without leaking write permission into
# the config subtree.
#
# Tamper boundary: /home/node itself stays node-owned (the agent needs a
# functional home dir), so an adversarial agent could `mv .nuget .nuget.bak
# && mkdir -p .nuget/NuGet && write a different config`. Defending against
# that would require CAP_LINUX_IMMUTABLE (chattr +i) or moving the config
# out of $HOME entirely — neither is a clean win for this image. The
# startup-check verifies the wiring on every container spawn, so the
# baseline state is observable. Casual modification, however, is blocked.
ENV NUGET_PACKAGES=/home/node/.nuget-cache
RUN mkdir -p /home/node/.nuget/NuGet \
    && printf '<?xml version="1.0" encoding="utf-8"?>\n\
<configuration>\n\
  <packageSources>\n\
    <clear />\n\
    <add key="Cache: api.nuget.org" value="https://api-nuget.markridgwell.com/v3/index.json" protocolVersion="3" />\n\
    <add key="Cache: FunFair" value="https://funfair-nuget.markridgwell.com/index.json" protocolVersion="3" />\n\
    <add key="Cache: FunFair (Prerelease)" value="https://funfair-prerelease-nuget.markridgwell.com/index.json" protocolVersion="3" />\n\
  </packageSources>\n\
</configuration>\n' > /home/node/.nuget/NuGet/NuGet.Config \
    && chown -R root:root /home/node/.nuget \
    && chmod 0755 /home/node/.nuget /home/node/.nuget/NuGet \
    && chmod 0444 /home/node/.nuget/NuGet/NuGet.Config \
    && mkdir -p /home/node/.nuget-cache \
    && chown -R node:node /home/node/.nuget-cache

# ---- .NET global tools (cache-bust daily so latest versions pull in) ---------
#
# CWM.RoslynNavigator — MCP-style Roslyn navigator, part of the dotnet-claude-kit
#   (https://codewithmukesh.com/resources/dotnet-claude-kit). The Claude Code
#   plugin side of the kit is installed at runtime inside Claude; only the
#   global tool gets baked here.
# dotnet-ef — Entity Framework CLI (migrations add/update/script).
# ilspycmd — ILSpy command-line decompiler (icsharpcode/ILSpy) for inspecting
#   .NET assemblies.
# dotnet-script — run C# scripts (.csx) directly without a project; useful for
#   one-off automation and quick experiments.
# Each tool gets its own RUN so:
#   - per-blob layer size stays modest (any one tool fits well under
#     typical registry edge body-size caps like Cloudflare's 100 MB).
#   - failure on one tool doesn't blow away the cache for the others.
# `: ${DOTNET_TOOLS_CACHE_BUST}` substitutes the ARG into the command
# text (no-op shell `:` discards it) so the buildkit cache key for
# every layer includes the cache-bust value — the layers re-install
# in lockstep when the ARG changes.
ARG DOTNET_TOOLS_CACHE_BUST
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.Changelog.Cmd"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.DotNet.Code.Analysis.Overrides.Cmd"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g TSQLLint"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g FunFair.BuildCheck"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g FunFair.BuildVersion"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g CWM.RoslynNavigator"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g dotnet-ef"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g ilspycmd"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Microsoft.SqlPackage"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g PowerShell"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g Credfeto.DotNet.Repo.Formatter"
RUN su node -c ": ${DOTNET_TOOLS_CACHE_BUST}; dotnet tool install -g dotnet-script"

# dotnet- subcommand aliases (see comment near profile.d earlier in this
# file). Some tools install only as `<name>` so `dotnet <name>` invocation
# fails; create the dotnet-X aliases now so they're present at every
# container start, no runtime patching needed. Idempotent: ln -sf overwrites.
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

# ---- dotnet-claude-kit repo (cloned for the Claude Code plugin side) ---------
RUN git clone --depth 1 https://github.com/codewithmukesh/dotnet-claude-kit.git /opt/dotnet-claude-kit \
    && chown -R node:node /opt/dotnet-claude-kit

# ---- wshobson/agents marketplace — sparse-checkout three plugins -------------
# The full repo is ~78 plugins; we only want javascript-typescript, python-
# development, and shell-scripting. `--filter=blob:none --sparse` pulls only
# the metadata up front, then sparse-checkout materialises just those subtrees.
RUN git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/wshobson/agents.git /opt/wshobson-agents \
    && cd /opt/wshobson-agents \
    && git sparse-checkout set \
        plugins/javascript-typescript \
        plugins/python-development \
        plugins/shell-scripting \
    && chown -R node:node /opt/wshobson-agents

# ---- akin-ozer/cc-devops-skills (GitHub Actions et al) ----------------------
RUN git clone --depth 1 https://github.com/akin-ozer/cc-devops-skills.git /opt/cc-devops-skills \
    && chown -R node:node /opt/cc-devops-skills

# ---- s2005/markdown-linter-fixer-skill (pinned) -----------------------------
RUN git clone --depth 1 --branch "${MARKDOWN_LINTER_FIXER_REF}" \
        https://github.com/s2005/markdown-linter-fixer-skill.git /opt/markdown-linter-fixer \
    && chown -R node:node /opt/markdown-linter-fixer

# ---- /opt/pre-commit (global pre-commit config) ------------------------------
# Cloned read-only into the image. The upstream's pre-commit working tree
# lives under src/ in the repo (config, hooks, scripts) alongside install
# scripts and shared lib/ helpers; we clone the whole repo as-is and strip
# only the top-level bits unrelated to the hook chain (repo .git metadata,
# GitHub Actions config, AI/agent docs). The hook shim and sanity asserts
# point at /opt/pre-commit/src/... directly — no path-rewriting gymnastics.
# /etc/gitconfig (baked in below) wires git's global core.hooksPath to
# /opt/git-global-hooks unconditionally — every commit in every repo in
# this container runs that config through pre-commit, with no opt-out path
# available to the agent.
#
# After cloning, the .git directory is deleted and provenance is recorded
# in /opt/pre-commit/.env (SHA=<sha>). This makes the directory look like
# a static install rather than a checkout, so an
# agent walking the filesystem won't run `git pull` or `git fetch` against
# it on a whim — there's no .git for git to operate on. The .env is
# informational only; nothing in the runtime reads it.
#
# Hard build-time assertion: if upstream ever renames or removes the
# config file the build fails right here, rather than silently producing
# an image where the hook shim invokes pre-commit against a missing path
# and breaks every commit at runtime.
#
# Owned by root (mode 0755 dirs / 0644 files left over from `git clone`) so
# the unprivileged `node` user that the agent runs as can read + execute but
# cannot modify anything in here — there is no path to escalate to root in
# the running container.
#
# Cache-bust ARG: bumped daily by container/build.sh so the clone refreshes
# when upstream picks up new commits, even when earlier Docker layers are
# still cached. Without this the layer would stay frozen at whatever HEAD
# was when this stage first built. Mirrors the DOTNET_TOOLS_CACHE_BUST
# pattern above; runtime auto-pull was rejected because it would defeat
# the root:root 0444 tamper lockdown enforced by startup-check.sh.
ARG CREDFETO_PRECOMMIT_CACHE_BUST
ARG PRECOMMIT_UPSTREAM=https://github.com/credfeto/credfeto-global-pre-commit.git
RUN git clone --depth 1 "$PRECOMMIT_UPSTREAM" /opt/pre-commit \
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
# point that runs the full chain: branch protection (blocks direct commits
# to main/master), merge-commit + ignored-file checks, the linting
# pre-commit run, dotnet buildtest (FunFair.BuildCheck), npm test,
# tsqllint/sqlfluff, cfn-lint. Running `pre-commit run` directly skips
# every step except the linting one, so the orchestrator must be the
# delegation target. If credfeto adds more hook stages (commit-msg, etc.),
# drop matching shims in here. Owned by root for the same reason as the
# clone above. Explicit chmod on the orchestrator is belt-and-braces in
# case upstream loses the +x bit.
RUN mkdir -p /opt/git-global-hooks && \
    chmod 0755 /opt/pre-commit/src/hooks/pre-commit && \
    printf '#!/bin/bash\nexec /opt/pre-commit/src/hooks/pre-commit "$@"\n' \
        > /opt/git-global-hooks/pre-commit && \
    chmod 0755 /opt/git-global-hooks/pre-commit && \
    chown -R root:root /opt/git-global-hooks

# ---- System-wide gitconfig (tamper-resistant) ------------------------------
# Baked in at /etc/gitconfig as root:root mode 0444. The unprivileged `node`
# user the agent runs as has no way to modify it — there is no sudo or
# setuid path in the image, so the only way to mutate this file is to
# rebuild the image.
#
# core.hooksPath is intentionally NOT in this file — entrypoint.sh layers
# it on at runtime after startup-check.sh finishes, so the meta-test's
# sanity commits don't drag the pre-commit hook into their critical path.
# (The credfeto clone above is asserted to ship src/.pre-commit-config.yaml
# at build time, so the entrypoint wiring is never aimed at a missing path.)
COPY system-gitconfig /etc/gitconfig
RUN chown root:root /etc/gitconfig \
    && chmod 0444 /etc/gitconfig \
    && git config --file /etc/gitconfig --list >/dev/null

# ---- Python tooling not available in apt -----------------------------------
# Trixie ships yamllint / ansible-lint / flake8 / pylint / pre-commit as
# native packages (installed in the apt block above). What remains on pip:
#   - uv, ruff           — Astral toolchain, too new for stable Debian.
#   - cfn-lint           — AWS CloudFormation linter, not in Debian.
#   - sqlfluff           — Trixie ships 3.3.1; we want the 4.x line. Pin via
#     SQLFLUFF_VERSION so rebuilds don't silently bump.
#   - pre-commit-hooks   — provides ~20 console_script bins (check-merge-
#     conflict, end-of-file-fixer, etc.) that the credfeto pre-commit config
#     calls as `language: system` entries. Without these the global pre-
#     commit hook fails with "Executable check-merge-conflict not found".
#
# pip's PEP 668 marker is acknowledged with --break-system-packages; the
# image is a sealed environment so global pip is fine and lands the
# binaries at /usr/local/bin.
#
# Split into two RUN steps because cfn-lint's dep tree (pydantic et al.)
# wants to upgrade typing_extensions, but the apt block above pulled in
# python3-typing-extensions as a transitive dep of ansible-lint. pip can't
# uninstall packages that don't carry a RECORD file (which apt-managed ones
# don't), so the upgrade attempt fails with `error: uninstall-no-record-file`.
# `--ignore-installed` tells pip to skip the uninstall step entirely and
# drop fresh copies into /usr/local/lib/python3.X/dist-packages — that path
# has higher priority than apt's /usr/lib path, so the new versions win at
# import time. uv/ruff don't have this problem because they're standalone
# Rust binaries with no Python dep tree to reconcile.
RUN pip3 install --break-system-packages --no-cache-dir \
        uv \
        ruff \
        "sqlfluff==${SQLFLUFF_VERSION}" \
        pre-commit-hooks
RUN pip3 install --break-system-packages --no-cache-dir --ignore-installed \
        cfn-lint

# ---- actionlint — companion CLI for the cc-devops-skills GitHub Actions ----
# Static binary release; the upstream installer script handles arch detection.
RUN curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash -o /tmp/install-actionlint.sh \
    && bash /tmp/install-actionlint.sh "${ACTIONLINT_VERSION}" /usr/local/bin \
    && rm /tmp/install-actionlint.sh \
    && actionlint -version

# ---- composite-action-lint -------------------------------------------------
# Built upstream-from-source by the multi-stage Go builder above (no release
# binaries are published). Lives at /opt/composite-action-lint/ alongside an
# .env recording HEAD + UPSTREAM (mirrors the /opt/pre-commit pattern: no
# .git anywhere, so an agent walking the FS can't `git pull` to update it).
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
    && chown -R root:root /opt/composite-action-lint \
    && composite-action-lint -h >/dev/null 2>&1 \
        || composite-action-lint --help >/dev/null 2>&1 \
        || test -x /usr/local/bin/composite-action-lint

# ---- trufflehog — secret scanner -------------------------------------------
# No Debian package available; upstream's install.sh handles arch detection
# and pulls a static binary from the GitHub release.
RUN curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
        | sh -s -- -b /usr/local/bin \
    && trufflehog --version

# ---- hadolint — Dockerfile linter ------------------------------------------
# Static binary; arch suffix differs (x86_64 / arm64).
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

# ---- dotenv-linter — .env file linter --------------------------------------
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

# ---- sqlcmd (microsoft/go-sqlcmd) — modern SQL Server CLI ------------------
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

# ---- Shared image-state checks (sourced at build + runtime) ----------------
# Single canonical list of /opt/* layout + binary-on-PATH checks. The sanity
# RUN block below sources it; container/startup-check.sh sources it too at
# runtime. A path/binary change in one file can't pass at one phase and fail
# at the other — the file IS the list. See lib/image-state-checks.sh.
COPY lib/image-state-checks.sh /usr/local/lib/nanoclaw/image-state-checks.sh
RUN chown root:root /usr/local/lib/nanoclaw/image-state-checks.sh \
    && chmod 0444 /usr/local/lib/nanoclaw/image-state-checks.sh

# ---- Build-time sanity check ------------------------------------------------
# Fails the build (not the agent at runtime) if:
#   - any required binary is missing
#   - HTTPS git clone is broken (cert chain, network, proxy)
#   - dotnet can't restore + build a real project (SDK + cert + NuGet feeds)
#   - gpg / sqlite3 can't run a minimal self-check
# The SSH-auth and mount-dependent tests live in container/startup-check.sh
# (runtime — keys aren't available here at build).
RUN set -e; \
    echo "== binary presence + version probe =="; \
    for cmd in git gh dotnet node bun python3 gpg curl pnpm sqlite3 claude \
               shellcheck bats shfmt checkbashisms uv ruff sqlfluff actionlint markdownlint-cli2 pre-commit \
               trufflehog hadolint dotenv-linter pwsh \
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
    # pre-commit-hooks console_script bins are tiny argparse entry points
    # that don't support --version (just --help). Probe them by presence
    # only — `pre-commit validate-config` further down actually exercises
    # the credfeto config that calls each one as language: system.
    for cmd in check-merge-conflict check-case-conflict check-added-large-files \
               end-of-file-fixer trailing-whitespace-fixer mixed-line-ending \
               check-toml detect-private-key check-executables-have-shebangs \
               check-shebang-scripts-are-executable check-json check-xml check-yaml; do \
        if ! command -v "$cmd" >/dev/null 2>&1; then \
            echo "FATAL sanity: pre-commit-hooks bin '$cmd' is missing — run 'pip install pre-commit-hooks'" >&2; exit 1; \
        fi; \
    done; \
    # ssh: -V flag (no --version). dash: no version flag — verify it can run.
    if ! ssh -V >/dev/null 2>&1; then echo "FATAL sanity: ssh -V did not exit 0" >&2; exit 1; fi; \
    if ! command -v dash >/dev/null 2>&1 || ! dash -c true; then echo "FATAL sanity: dash not runnable" >&2; exit 1; fi; \
    echo "== dotnet tools =="; \
    for tool in credfeto.changelog.cmd credfeto.dotnet.code.analysis.overrides.cmd tsqllint funfair.buildcheck funfair.buildversion cwm.roslynnavigator dotnet-ef ilspycmd microsoft.sqlpackage powershell credfeto.dotnet.repo.formatter dotnet-script; do \
        if ! su node -c "dotnet tool list -g" | awk '{print tolower($1)}' | grep -Fxq "$tool"; then \
            echo "FATAL sanity: dotnet tool '$tool' is missing" >&2; exit 1; \
        fi; \
    done; \
    echo "== image-state checks (shared with runtime startup-check) =="; \
    check_image() { _label="$1"; shift; "$@" || { echo "FATAL sanity: $_label" >&2; exit 1; }; }; \
    . /usr/local/lib/nanoclaw/image-state-checks.sh; \
    image_state_checks; \
    echo "== cwm-roslyn-navigator functional probe (build-only) =="; \
    su node -c "cwm-roslyn-navigator --help >/dev/null 2>&1" \
        || { echo "FATAL sanity: cwm-roslyn-navigator --help did not exit 0" >&2; exit 1; }; \
    echo "== gpg + sqlite3 self-check =="; \
    echo "probe" | gpg --dearmor >/dev/null 2>&1 || gpg --version >/dev/null; \
    sqlite3 :memory: "SELECT 1;" | grep -q 1; \
    echo "== HTTPS clone (dnyw4l3n13/scratch — sacrificial sanity target) =="; \
    rm -rf /tmp/sanity-clone; \
    # GIT_CONFIG_SYSTEM=/dev/null bypasses the url.https→ssh rewrite baked
    # into /etc/gitconfig — the build environment has no SSH key, so we must
    # exercise the genuine HTTPS path here.
    GIT_CONFIG_SYSTEM=/dev/null git clone --depth 1 https://github.com/dnyw4l3n13/scratch.git /tmp/sanity-clone; \
    test -d /tmp/sanity-clone/.git; \
    rm -rf /tmp/sanity-clone; \
    echo "== all build-time checks passed =="; \
    echo "  versions: git $(git --version | awk '{print $3}'), $(ssh -V 2>&1 | cut -d, -f1), $(gh --version | head -1), dotnet $(dotnet --version), node $(node --version), bun $(bun --version), claude $(claude --version 2>&1 | head -1)"

# ---- /opt/pre-commit acceptance suite (end-to-end hook orchestrator test) --
# Run the upstream credfeto acceptance script against the installed hook
# chain. Each test creates an isolated git repo, stages a curated good/bad
# fixture, and asserts the hook accepts or rejects the commit with the
# expected exit code (covers branch protection, dotnet-path validation, env/
# xml/ps1/js/workflow/css/playbook/sql/composite-action/py/dockerfile linters,
# and the freshness-SHA check). A failure here means the published
# nanoclaw-base image would ship a known-broken commit pipeline — better to
# fail the build now than every commit at runtime.
#
# Placed after the sanity check on purpose: all tooling the orchestrator
# invokes (dotnet tools, pnpm globals, pip bins, static binaries) is now
# installed and version-probed, and the real dotnet lives at the
# /usr/share/dotnet/dotnet path the hook's environment-sanity rule expects.
#
# Survives layer caching the same way the clone does: the daily
# CREDFETO_PRECOMMIT_CACHE_BUST ARG invalidates the clone RUN above, which
# cascades through every later layer including this one — so the suite
# always runs against the same upstream commit it was shipped with.
#
# Why copy-to-/tmp + run-as-node rather than running in place:
#   - The dotnet tools (tsqllint, FunFair.BuildCheck, etc.) are installed into
#     the node user's per-user profile (su node -c "dotnet tool install -g …"
#     above), so the orchestrator's `dotnet tool list --global` presence
#     check only finds them when run as node. Running the suite as root
#     spuriously fails the tsqllint test.
#   - The script's EXIT trap unconditionally removes $REPO_DIR/.env (it
#     treats the file as test-owned cruft) and several freshness tests
#     write to $REPO_DIR/.env directly. Running against /opt/pre-commit in
#     place would destroy the provenance .env that startup-check.sh later
#     asserts is present, and require the node user to be able to write
#     into the root-owned tree.
#   - The script computes its own root from $0's dirname (HOOKS_REPO_DIR),
#     so a copy at any path works as long as the layout is preserved.
# We strip .env from the copy up front: the upstream suite assumes a clean
# state and the dedicated freshness tests write/remove their own .env. With
# .env absent at startup, the orchestrator's network-dependent freshness
# check is silently skipped for every non-freshness test — matching the
# upstream test contract.
RUN set -e; \
    cp -a /opt/pre-commit /tmp/pre-commit-test; \
    rm -f /tmp/pre-commit-test/.env; \
    chown -R node:node /tmp/pre-commit-test; \
    su node -c /tmp/pre-commit-test/acceptance-test; \
    rm -rf /tmp/pre-commit-test

# Debian trixie ships gpg 2.4.x natively — matches the host's keybox format
# (public-keys.d/ + use-keyboxd) so --list-secret-keys and signed commits work
# against a copy of the host's ~/.gnupg. Bookworm's 2.2.x could not.
# Symlink gpg2 → gpg so gitconfigs that pin gpg.program=/usr/bin/gpg2
# (Debian's convention) work without an env override.
RUN ln -sf /usr/bin/gpg /usr/bin/gpg2

# ---- pnpm-side registry config (mirror /etc/npmrc for pnpm 11+) -------------
# pnpm 11.0.x silently dropped /etc/npmrc support, so the runtime agent's
# `pnpm config get registry` returned the public default even though
# /etc/npmrc and NPM_CONFIG_REGISTRY both pointed at the local mirror —
# breaking startup-check the moment corepack auto-bumped to v11.
#
# pnpm 11 reads (per `pnpm help config` + empirical probe):
#   - ~/.npmrc                       (per-user)
#   - ~/.config/pnpm/config.yaml     (per-user, YAML — pnpm-specific)
# It explicitly does NOT read:
#   - /etc/npmrc, /etc/pnpmrc        (no system-wide config support)
#   - ~/.config/pnpm/rc, ~/.pnpmrc   (legacy / never-defined paths)
# NPM_CONFIG_REGISTRY env is also ignored by pnpm 11.
#
# Solution: bake per-user config files in both root (build-time pnpm) and
# node (runtime pnpm) homes, root-owned 0444 so the unprivileged agent can
# read but not modify — same tamper pattern as /etc/gitconfig and the
# locked-down NuGet config. Parent dirs root:root 0755 so the file can't be
# replaced by an in-place rewrite (agent could still `mv` the parent dir
# since /home/node itself is node-owned, but startup-check observes the
# baseline state on every spawn, same trade-off documented for /home/node/.nuget).
#
# Positioned this late on purpose — keeps every earlier RUN cached when
# only this config needs touching.
RUN echo "registry=https://npm.markridgwell.com/" >> /root/.npmrc && \
    chown root:root /root/.npmrc && chmod 0644 /root/.npmrc && \
    mkdir -p /home/node/.config/pnpm && \
    printf 'registry: https://npm.markridgwell.com/\n' \
        > /home/node/.config/pnpm/config.yaml && \
    chown -R root:root /home/node/.config && \
    chmod 0755 /home/node/.config /home/node/.config/pnpm && \
    chmod 0444 /home/node/.config/pnpm/config.yaml

# Entrypoint scripts, /workspace setup, USER node, WORKDIR, and ENTRYPOINT
# all live in the customisation layer (container/Dockerfile) so iterating on
# them doesn't trigger a 20-minute base rebuild. Image ends here as root, no
# WORKDIR — the customisation Dockerfile takes it from there.
