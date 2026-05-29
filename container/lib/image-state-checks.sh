# shellcheck shell=sh
#
# Single source of truth for /opt/* layout and image-baked binary checks.
# Sourced by BOTH:
#   - container/base.Dockerfile's build-time sanity RUN block — fails the
#     base image build (and so the GHCR rebuild) on any check failure.
#   - container/startup-check.sh at container start — accumulates pass/fail
#     into the runtime structured report; failed checks trip exit code 42.
#
# The caller defines `check_image <label> <cmd> [args...]` to wire the
# checks into its own failure handling. This keeps a single canonical list
# of checks; previously a copy lived in each consumer and the two drifted
# (commit ec97ea3 fixed an outage caused exactly by that drift after we
# moved /opt/pre-commit/{config,hooks} into /opt/pre-commit/src/).
#
# Strictly image state — anything depending on per-session mounts (creds,
# agent group folder, workspace, session DB) belongs in startup-check.sh.
# Anything build-only (network probes, multi-stage builder outputs) belongs
# in base.Dockerfile and not here.

image_state_checks() {
    # /opt/pre-commit — credfeto-global-pre-commit clone with .git
    # removed; upstream working tree lives at src/.
    check_image "pre-commit config present" \
        test -f /opt/pre-commit/src/.pre-commit-config.yaml
    check_image "pre-commit provenance .env present" \
        test -f /opt/pre-commit/.env
    check_image "pre-commit .git removed" \
        test ! -e /opt/pre-commit/.git
    check_image "pre-commit orchestrator script is executable" \
        test -x /opt/pre-commit/src/hooks/pre-commit
    check_image "pre-commit validate-config" \
        pre-commit validate-config /opt/pre-commit/src/.pre-commit-config.yaml

    # /opt/git-global-hooks shim — entrypoint.sh wires core.hooksPath at
    # runtime to /opt/git-global-hooks. The shim must exec the upstream
    # orchestrator; a regression to `pre-commit run --config ...` silently
    # skips every non-linting stage.
    check_image "git-global-hooks shim is executable" \
        test -x /opt/git-global-hooks/pre-commit
    check_image "git-global-hooks shim delegates to /opt/pre-commit orchestrator" \
        grep -Fq /opt/pre-commit/src/hooks/pre-commit /opt/git-global-hooks/pre-commit

    # Hook bins referenced by the pre-commit config — `language: system`
    # so there is no managed-environment cache to fall back to. Drift
    # between upstream config and the installed tool set surfaces here
    # rather than as a first-commit failure inside an agent session.
    for _bin in check-merge-conflict end-of-file-fixer trailing-whitespace-fixer \
                shellcheck yamllint flake8 markdownlint ansible-lint; do
        check_image "pre-commit hook bin: $_bin on PATH" command -v "$_bin"
    done

    # /opt/composite-action-lint — built upstream-from-source (no release
    # binaries published). Symlinked to /usr/local/bin/.
    check_image "composite-action-lint binary executable" \
        test -x /opt/composite-action-lint/composite-action-lint
    check_image "composite-action-lint on PATH" \
        command -v composite-action-lint
    check_image "composite-action-lint provenance .env present" \
        test -f /opt/composite-action-lint/.env
    check_image "composite-action-lint .git removed" \
        test ! -e /opt/composite-action-lint/.git

    # /opt/dotnet-claude-kit — loaded by Claude Code via --plugin-dir;
    # cwm-roslyn-navigator is its MCP binary, installed via dotnet tool.
    check_image "dotnet-claude-kit plugin manifest" \
        test -f /opt/dotnet-claude-kit/.claude-plugin/plugin.json
    check_image "dotnet-claude-kit .mcp.json" \
        test -f /opt/dotnet-claude-kit/.mcp.json
    check_image "dotnet-claude-kit agents/ non-empty" \
        sh -c '[ -n "$(ls -A /opt/dotnet-claude-kit/agents 2>/dev/null)" ]'
    check_image "dotnet-claude-kit skills/ non-empty" \
        sh -c '[ -n "$(ls -A /opt/dotnet-claude-kit/skills 2>/dev/null)" ]'
    check_image "dotnet-claude-kit commands/ non-empty" \
        sh -c '[ -n "$(ls -A /opt/dotnet-claude-kit/commands 2>/dev/null)" ]'
    check_image "dotnet-claude-kit cwm-roslyn-navigator on PATH" \
        command -v cwm-roslyn-navigator

    # /opt/wshobson-agents — sparse-checkout of the three plugins we use.
    check_image "wshobson-agents javascript-typescript plugin" \
        test -f /opt/wshobson-agents/plugins/javascript-typescript/.claude-plugin/plugin.json
    check_image "wshobson-agents python-development plugin" \
        test -f /opt/wshobson-agents/plugins/python-development/.claude-plugin/plugin.json
    check_image "wshobson-agents shell-scripting plugin" \
        test -f /opt/wshobson-agents/plugins/shell-scripting/.claude-plugin/plugin.json

    # /opt/cc-devops-skills — GitHub Actions et al skills.
    check_image "cc-devops-skills plugin manifest" \
        test -f /opt/cc-devops-skills/devops-skills-plugin/.claude-plugin/plugin.json

    # /opt/markdown-linter-fixer — markdown linter Claude plugin.
    check_image "markdown-linter-fixer plugin manifest" \
        test -f /opt/markdown-linter-fixer/.claude-plugin/plugin.json

    # Real Microsoft Arial — installed by ttf-mscorefonts-installer, which
    # downloads MS core fonts from SourceForge during apt postinst. Required
    # by SixLabors.Fonts and other name-record-lookup font stacks: they
    # scan font files and match by the internal family-name record, which
    # for Liberation Sans is literally "Liberation Sans" (fontconfig's
    # Arial→Liberation alias is invisible to them). File-based check (not
    # fc-list) so we mirror what SixLabors.Fonts actually does and don't
    # depend on the fontconfig cache being warm. If the SourceForge fetch
    # silently fails at build time, this check is the canary.
    check_image "Arial font file installed" \
        sh -c 'find /usr/share/fonts -iname arial.ttf -print -quit | grep -q .'
}
