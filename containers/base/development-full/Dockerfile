# syntax=docker/dockerfile:1.7
# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-python:latest

# Use bash with pipefail for all subsequent RUN instructions so that pipes
# fail the step on any non-zero exit in the pipeline, not just the last command.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Build-time arguments ----------------------------------------------------
ARG DOTNET_TOOLS_CACHE_BUST
ARG CREDFETO_PRECOMMIT_CACHE_BUST
ARG CREDFETO_AI_SKILLS_CACHE_BUST
ARG PRECOMMIT_UPSTREAM=https://github.com/credfeto/credfeto-global-pre-commit.git
ARG MARKDOWN_LINTER_FIXER_REF=v1.5.4
ARG CC_DEVOPS_SKILLS_REF=v1.0.0
# Pins for external GitHub repo clones so upstream cannot silently change what
# is baked into the image. Policy per repo (re-evaluate the choice, not just
# the value, whenever bumping):
#   - Third-party repos with a current, compatible tagged release: pin to
#     that tag (REF) and verify the commit it resolves to (COMMIT) — a tag
#     mutation is caught immediately. See cc-devops-skills / markdown-linter-fixer.
#   - Third-party repos with no usable tag: pin to an exact commit SHA,
#     fetched directly (`git fetch <url> <sha>`) rather than cloned from the
#     moving default-branch tip — this only fails the build if that commit
#     becomes unreachable (a force-push/history rewrite), not merely because
#     main has advanced. dotnet-claude-kit's only tag (v0.7.0) is stale and
#     predates a skill-catalog refactor this image depends on, so it is
#     pinned this way instead of to that tag. wshobson/agents publishes no
#     tags at all, so it is pinned this way too.
#   - credfeto-owned repos are implicitly trusted: credfeto-global-pre-commit
#     always tracks live main HEAD with no pinned-commit assertion.
ARG DOTNET_CLAUDE_KIT_COMMIT=cbad34af27faf94b52a86694925b91ba49f3d10c
ARG WSHOBSON_AGENTS_COMMIT=5cc2549a50fc672230efd0a0307e2fd27ffba792
ARG CC_DEVOPS_SKILLS_COMMIT=7fe7595e4512f8ce43dcf956aa5190b96d627dd1
ARG MARKDOWN_LINTER_FIXER_COMMIT=72aedc7915a0918d897b63b28d935989c054585e

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
    ln -sf tsqllint              /home/developer/.dotnet/tools/dotnet-tsqllint && \
    ln -sf pwsh                  /home/developer/.dotnet/tools/dotnet-pwsh'

# PSScriptAnalyzer PowerShell module — check-setup imports it
# (`dotnet pwsh -Command "Import-Module PSScriptAnalyzer ..."`) to validate
# the VALIDATE_POWERSHELL hook, so it must be present for the developer user
# in addition to the pwsh binary/alias above. Installed via Install-PSResource
# (Microsoft.PowerShell.PSResourceGet, bundled with pwsh 7.4+) rather than the
# legacy Install-Module: the latter needs the old PackageManagement "NuGet"
# provider bootstrapped first, which fails non-interactively here ("No match
# was found for the specified search criteria for the provider 'NuGet'") even
# though the PSGallery endpoint itself is reachable. PSResourceGet talks to
# the gallery directly and needs no such bootstrap.
# hadolint ignore=DL3059
RUN su developer -c 'dotnet pwsh -NoProfile -NonInteractive -Command \
    "Install-PSResource -Name PSScriptAnalyzer -Scope CurrentUser -TrustRepository -ErrorAction Stop"'

# ---- dotnet-claude-kit repo (cloned for the Claude Code plugin side) ---------
# Fetches the exact pinned commit directly (not the moving default-branch
# tip), so this only fails if that commit becomes unreachable upstream.
RUN git init -q /opt/dotnet-claude-kit \
    && git -C /opt/dotnet-claude-kit fetch -q --depth 1 \
        https://github.com/codewithmukesh/dotnet-claude-kit.git "${DOTNET_CLAUDE_KIT_COMMIT}" \
    && git -C /opt/dotnet-claude-kit checkout -q FETCH_HEAD \
    && chown -R root:root /opt/dotnet-claude-kit

# ---- wshobson/agents marketplace — sparse-checkout three plugins -------------
# The full repo is ~78 plugins; we only want javascript-typescript, python-
# development, and shell-scripting. `--filter=blob:none` pulls only the
# metadata up front, then sparse-checkout materialises just those subtrees.
# Upstream publishes no tags, so this fetches the exact pinned commit
# directly (not the moving default-branch tip) — see dotnet-claude-kit above.
# hadolint ignore=DL3059
RUN git init -q /opt/wshobson-agents \
    && git -C /opt/wshobson-agents sparse-checkout init --cone \
    && git -C /opt/wshobson-agents fetch -q --depth 1 --filter=blob:none \
        https://github.com/wshobson/agents.git "${WSHOBSON_AGENTS_COMMIT}" \
    && git -C /opt/wshobson-agents sparse-checkout set \
        plugins/javascript-typescript \
        plugins/python-development \
        plugins/shell-scripting \
    && git -C /opt/wshobson-agents checkout -q FETCH_HEAD \
    && chown -R root:root /opt/wshobson-agents

# ---- akin-ozer/cc-devops-skills (GitHub Actions et al) ----------------------
# CC_DEVOPS_SKILLS_REF is the git tag used for the shallow clone.
# CC_DEVOPS_SKILLS_COMMIT is the full commit SHA that tag currently resolves
# to; the build verifies the two match so a tag mutation is caught immediately.
# hadolint ignore=DL3059
RUN git clone --depth 1 --branch "${CC_DEVOPS_SKILLS_REF}" \
        https://github.com/akin-ozer/cc-devops-skills.git /opt/cc-devops-skills \
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

# ---- credfeto/credfeto-ai-skills (Claude Code skill definitions) ------------
# credfeto-owned, so — like credfeto-global-pre-commit — this always tracks
# live main HEAD with no pinned-commit assertion. Unlike the pinned
# third-party sources above, the skill set here is explicitly expected to
# grow and shrink over time, so it is not counted against a fixed number.
# hadolint ignore=DL3059
RUN : "${CREDFETO_AI_SKILLS_CACHE_BUST}"; \
    git clone --depth 1 https://github.com/credfeto/credfeto-ai-skills.git /opt/credfeto-ai-skills \
    && test -d /opt/credfeto-ai-skills/ai/skills \
    && chown -R root:root /opt/credfeto-ai-skills

# ---- Link cloned skill repos into ~/.claude/skills --------------------------
# Claude Code discovers "personal" skills as immediate subdirectories of
# ~/.claude/skills/, each containing a SKILL.md. The repos above are cloned to
# /opt/* but their skills/ subtrees are nested at different depths per repo, so
# symlink each individual skill dir in rather than the repo root. Symlink
# targets are root:root 0755 (read/execute only), so the links stay
# non-writable by developer even though the symlink itself is created under
# ~/.claude. Driven by `find -maxdepth 1` over each repo's skills/ subtree
# (rather than a hardcoded name list) so newly added upstream skills are
# picked up automatically as long as they still land under a skills/ folder —
# credfeto-ai-skills in particular is expected to gain/lose skills over time.
# The resulting count is recorded to /opt/.claude-skill-count (rather than
# hardcoded in the sanity check below) so the check stays correct as any
# source's skill set changes, while still catching a broken symlink pass.
# hadolint ignore=DL3059
RUN mkdir -p /home/developer/.claude/skills \
    && chown root:root /home/developer/.claude \
    && chmod 0755 /home/developer/.claude \
    && for skills_root in \
        /opt/dotnet-claude-kit/skills \
        /opt/wshobson-agents/plugins/javascript-typescript/skills \
        /opt/wshobson-agents/plugins/python-development/skills \
        /opt/wshobson-agents/plugins/shell-scripting/skills \
        /opt/cc-devops-skills/devops-skills-plugin/skills \
        /opt/markdown-linter-fixer/skills \
        /opt/credfeto-ai-skills/ai/skills; do \
        test -d "${skills_root}" || { echo "FATAL: skills root ${skills_root} is missing" >&2; exit 1; }; \
        prefix=""; \
        case "${skills_root}" in \
            /opt/credfeto-ai-skills/*) prefix="credfeto-" ;; \
        esac; \
        find "${skills_root}" -mindepth 1 -maxdepth 1 -type d -print0 \
            | while IFS= read -r -d '' skill_dir; do \
                skill_name="${prefix}$(basename "${skill_dir}")"; \
                target="/home/developer/.claude/skills/${skill_name}"; \
                test ! -e "${target}" \
                    || { echo "FATAL: duplicate skill name '${skill_name}' (from ${skill_dir})" >&2; exit 1; }; \
                ln -s "${skill_dir}" "${target}"; \
              done; \
    done \
    && find /home/developer/.claude/skills -mindepth 1 -maxdepth 1 -type l | wc -l > /opt/.claude-skill-count \
    && chown -R root:root /home/developer/.claude/skills /opt/.claude-skill-count \
    && chmod 0444 /opt/.claude-skill-count

# ---- Bake in Claude Code settings, policy-limits, and hooks -----------------
# Copied from the operator's ~/.claude/{settings.json,policy-limits.json,hooks/}
# into source control here so they are version-controlled and reproducible.
# root:root so the developer user cannot tamper with them at runtime; oneshot
# does not (and must not) bind-mount over these paths — see containers/agent/Dockerfile.
COPY --chown=root:root --chmod=0444 claude-settings.json /home/developer/.claude/settings.json
COPY --chown=root:root --chmod=0444 claude-policy-limits.json /home/developer/.claude/policy-limits.json
COPY --chown=root:root --chmod=0755 claude-hooks/enforce-git-dash-c /home/developer/.claude/hooks/enforce-git-dash-c
COPY --chown=root:root --chmod=0755 claude-hooks/enforce-git-identity /home/developer/.claude/hooks/enforce-git-identity
COPY --chown=root:root --chmod=0755 claude-hooks/reject-obfuscated-commands /home/developer/.claude/hooks/reject-obfuscated-commands
COPY --chown=root:root --chmod=0755 claude-hooks/block-git-worktree /home/developer/.claude/hooks/block-git-worktree
COPY --chown=root:root --chmod=0444 claude-hooks/command-allowlist /home/developer/.claude/hooks/command-allowlist
COPY --chown=root:root --chmod=0444 claude-hooks/command-blocklist /home/developer/.claude/hooks/command-blocklist
COPY --chown=root:root --chmod=0444 claude-hooks/env-var-blocklist /home/developer/.claude/hooks/env-var-blocklist
RUN chown root:root /home/developer/.claude/hooks \
    && chmod 0755 /home/developer/.claude/hooks

# ---- /opt/pre-commit (global pre-commit config) + hook shims ----------------
# Clone the upstream config repo, record provenance in .env, strip git
# metadata, then wire up shims in /opt/git-global-hooks (referenced by
# core.hooksPath in /etc/gitconfig). credfeto/credfeto-global-pre-commit is
# credfeto-owned, so this always tracks live main HEAD — no pinned-commit
# assertion, unlike the third-party clones above.
# hadolint ignore=DL3059
RUN : "${CREDFETO_PRECOMMIT_CACHE_BUST}"; \
    git clone --depth 1 "$PRECOMMIT_UPSTREAM" /opt/pre-commit \
    && test -f /opt/pre-commit/src/.pre-commit-config.yaml \
    && HEAD_SHA="$(git -C /opt/pre-commit rev-parse HEAD)" \
    && rm -rf /opt/pre-commit/.git \
              /opt/pre-commit/.github \
              /opt/pre-commit/.ai-instructions \
              /opt/pre-commit/ai \
              /opt/pre-commit/CLAUDE.md \
              /opt/pre-commit/install \
              /opt/pre-commit/install-deps-arch \
              /opt/pre-commit/install-deps-debian \
              /opt/pre-commit/lib \
    && printf 'SHA=%s\n' "$HEAD_SHA" > /opt/pre-commit/.env \
    && mkdir -p /opt/git-global-hooks \
    && printf '#!/bin/bash\nexec /opt/pre-commit/src/hooks/pre-commit "$@"\n' \
        > /opt/git-global-hooks/pre-commit \
    && printf '#!/bin/bash\nexec /opt/pre-commit/src/hooks/pre-push "$@"\n' \
        > /opt/git-global-hooks/pre-push \
    && chmod 0755 /opt/git-global-hooks/pre-commit /opt/git-global-hooks/pre-push \
    && chown -R root:root /opt/pre-commit /opt/git-global-hooks

# Make pre-commit helper scripts available on PATH so pre-commit hooks that
# invoke them (e.g. run-bats, buildcheck) can be found without a full path.
# The directory is root-owned (traversable but not writable by the agent user).
ENV PATH="/opt/pre-commit/src/scripts:${PATH}"

# ---- System-wide gitconfig (tamper-resistant) --------------------------------
# Baked in at /etc/gitconfig as root:root mode 0444. The unprivileged
# `developer` user the agent runs as has no way to modify it.
# Build context must be containers/base/development-full so this COPY path resolves correctly.
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
    test -x /opt/git-global-hooks/pre-push \
        || { echo "FATAL sanity: /opt/git-global-hooks/pre-push is not executable" >&2; exit 1; }; \
    for wrapper in run-eslint run-stylelint run-psscriptanalyzer run-bats; do \
        command -v "$wrapper" >/dev/null 2>&1 \
            || { echo "FATAL sanity: $wrapper not on PATH — /opt/pre-commit/src/scripts/ missing from PATH?" >&2; exit 1; }; \
    done; \
    echo "== Claude Code settings/policy-limits/hooks wiring =="; \
    for f in /home/developer/.claude/settings.json /home/developer/.claude/policy-limits.json; do \
        [ "$(stat -c '%U:%G %a' "$f")" = "root:root 444" ] \
            || { echo "FATAL sanity: $f has wrong owner/perms" >&2; exit 1; }; \
    done; \
    [ "$(stat -c '%U:%G %a' /home/developer/.claude/hooks/enforce-git-dash-c)" = "root:root 755" ] \
        || { echo "FATAL sanity: enforce-git-dash-c hook has wrong owner/perms" >&2; exit 1; }; \
    [ -x /home/developer/.claude/hooks/enforce-git-dash-c ] \
        || { echo "FATAL sanity: enforce-git-dash-c hook is not executable" >&2; exit 1; }; \
    [ "$(stat -c '%U:%G %a' /home/developer/.claude/hooks/enforce-git-identity)" = "root:root 755" ] \
        || { echo "FATAL sanity: enforce-git-identity hook has wrong owner/perms" >&2; exit 1; }; \
    [ -x /home/developer/.claude/hooks/enforce-git-identity ] \
        || { echo "FATAL sanity: enforce-git-identity hook is not executable" >&2; exit 1; }; \
    [ "$(stat -c '%U:%G %a' /home/developer/.claude/hooks/reject-obfuscated-commands)" = "root:root 755" ] \
        || { echo "FATAL sanity: reject-obfuscated-commands hook has wrong owner/perms" >&2; exit 1; }; \
    [ -x /home/developer/.claude/hooks/reject-obfuscated-commands ] \
        || { echo "FATAL sanity: reject-obfuscated-commands hook is not executable" >&2; exit 1; }; \
    [ "$(stat -c '%U:%G %a' /home/developer/.claude/hooks/block-git-worktree)" = "root:root 755" ] \
        || { echo "FATAL sanity: block-git-worktree hook has wrong owner/perms" >&2; exit 1; }; \
    [ -x /home/developer/.claude/hooks/block-git-worktree ] \
        || { echo "FATAL sanity: block-git-worktree hook is not executable" >&2; exit 1; }; \
    for f in command-allowlist command-blocklist env-var-blocklist; do \
        [ "$(stat -c '%U:%G %a' /home/developer/.claude/hooks/$f)" = "root:root 444" ] \
            || { echo "FATAL sanity: hook policy file $f missing or wrong owner/perms" >&2; exit 1; }; \
    done; \
    echo "== Claude Code skills wiring =="; \
    skill_count=$(find /home/developer/.claude/skills -mindepth 1 -maxdepth 1 -type l | wc -l); \
    expected_skill_count=$(cat /opt/.claude-skill-count); \
    [ "$skill_count" -eq "$expected_skill_count" ] && [ "$skill_count" -gt 0 ] \
        || { echo "FATAL sanity: expected $expected_skill_count skill symlinks in ~/.claude/skills (recorded at build time), found $skill_count" >&2; exit 1; }; \
    for skill in markdown-linter-fixer tdd k8s-debug python-type-safety bash-defensive-patterns terraform-validator credfeto-git-commit; do \
        test -f "/home/developer/.claude/skills/${skill}/SKILL.md" \
            || { echo "FATAL sanity: skill '$skill' missing or has no SKILL.md" >&2; exit 1; }; \
    done; \
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

# ---- /opt/pre-commit setup health-check (fail build if incomplete) ----------
# check-setup validates the bundled pre-commit config (`pre-commit validate-config`)
# and asserts every tool the hooks dispatch is installed and on PATH, exiting
# non-zero if the config is invalid or anything is missing. On a generic CI runner
# some tools are legitimately absent, so its non-zero exit is tolerated there — but
# this image installs the full toolchain by design, so a non-zero exit here means a
# tool or config regression and MUST fail the build. Run as the developer user so it
# sees the same PATH and per-user dotnet global tools (cscleanup, pwsh, …) that exist
# at runtime; check-setup performs no network/.env access, so no /tmp copy is needed.
# hadolint ignore=DL3059
RUN su developer -c /opt/pre-commit/check-setup

# Bake the git SHA of the orchestrator commit that built this image layer into the
# environment so entrypoint.sh can log it for debugging. Placed last so changing
# the SHA only invalidates this cheap final layer.
ARG BUILD_GIT_SHA=unknown
ENV IMAGE_SHA_DEVELOPMENT_FULL=${BUILD_GIT_SHA}
