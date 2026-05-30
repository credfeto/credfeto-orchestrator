<!-- Locally Maintained -->
# Docker Base Image Instructions

[Back to Local Instructions Index](index.md)

> Load when: working on any file under `containers/base/` or any `.github/workflows/build-development-*.yml` workflow.

## Image Hierarchy

The four development base images form a strict chain:

```text
debian:trixie-slim
  └── development-tools  (apt packages, .NET SDK, static binary linters)
        └── development-node  (Node.js, Bun, npm globals)
              └── development-python  (pip tools)
                    └── development-full  (.NET global tools, pre-commit, skill repos)
```

Each image is built and pushed to `ghcr.io/<owner>/<image>:YYYY-MM-DD` and `:latest`.

## Lock-Down Requirements (MANDATORY)

Every file and directory installed by the build that an agent must not modify MUST be owned `root:root` with write permission removed:

- Tamper-resistant files: `root:root mode 0444` (read-only for all)
- Tamper-resistant directories: `root:root mode 0755` (traversable but not writable by non-root)
- Agent-writable files/directories: `developer:developer mode 0755` (only where explicitly needed)

Examples of correctly locked-down artefacts:

- `/etc/gitconfig` — global git config, root:root 0444
- `/home/developer/.nuget/NuGet/NuGet.Config` — NuGet feed list, root:root 0444
- `/opt/pre-commit/` — pre-commit hook repo, root:root 0755
- `/opt/git-global-hooks/` — hook shim directory, root:root 0755
- `/opt/composite-action-lint/` — linter binary, root:root 0755

## Self-Check Requirements (MANDATORY)

Every Dockerfile MUST end with a `RUN set -e; ...` self-check block that:

1. Verifies every binary installed in THIS stage responds to `--version` (or equivalent)
2. Re-verifies ALL inherited binaries from every previous stage
3. Includes `ssh -V` (not `--version`) for the SSH client
4. Includes a live HTTPS `git clone --depth 1` against a sacrificial public repo (`dnyw4l3n13/scratch`) with `GIT_CONFIG_SYSTEM=/dev/null` to bypass the url.https→ssh rewrite
5. Fails the build (not runtime) if any check fails — a broken image must never be pushed

## ARG Cache-Busting Pattern

For every layer that clones an external git repo or installs a versioned tool, use the no-op shell `: "$ARG_VALUE"` trick to embed the ARG in the layer cache key:

```dockerfile
ARG SOME_CACHE_BUST
RUN : "${SOME_CACHE_BUST}"; \
    git clone --depth 1 "$UPSTREAM" /opt/tool
```

Without this, changing the ARG in the workflow has no effect on the cached layer.

## Workflow Build Chain

Each workflow (except `build-development-tools.yml`) MUST include a `workflow_run` trigger that fires when the preceding stage completes on `main`, in addition to the cron fallback:

```yaml
on:
  workflow_run:
    workflows: ["Build development-<prev-stage> base image"]
    types: [completed]
    branches: ["main"]
```

The build job MUST include an `if` condition so it skips when the parent workflow failed:

```yaml
    if: ${{ github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success' }}
```

Stage 2-4 workflows MUST include `pull: true` in the build-push step to ensure the base `:latest` image is always pulled fresh.

## File Placement

- Dockerfiles: `containers/base/<stage>/Dockerfile`
- Files COPYd into images: place them alongside the Dockerfile in `containers/base/<stage>/` — do not reference files from other directories
- Workflows: `.github/workflows/build-development-<stage>.yml`
- Cron schedules: staggered by 15 min per stage (tools: :00, node: :15, python: :30, full: :45)
