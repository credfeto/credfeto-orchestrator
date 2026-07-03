<!-- Locally Maintained -->
# Docker Base Image Instructions

[Back to Local Instructions Index](index.md)

> Load when: working on any file under `containers/base/` or any `.github/workflows/build-development-*.yml` workflow.

## Image Hierarchy

The base images form a strict chain, topped by a locked-down agent layer:

```text
debian:trixie-slim
  └── development-tools   (apt packages, .NET SDK, static binary linters)
        └── development-node   (Node.js, Bun, npm globals)
              └── development-python   (pip tools)
                    └── development-full   (.NET global tools, pre-commit, skill repos, system-gitconfig)
                          └── development-agent   (removes pkg-mgmt/sudo, adds agent-entrypoint)
```

`development-agent` (`ghcr.io/credfeto/development-agent:latest`) is the image the orchestrator actually runs.
Each image is built and pushed to `ghcr.io/<owner>/<image>:latest`.

## Build Contexts (MANDATORY)

The build context for each image is the directory containing its Dockerfile — **never the repo root**:

| Image | Dockerfile | CI context |
| --- | --- | --- |
| development-tools | `containers/base/development-tools/Dockerfile` | `containers/base/development-tools` |
| development-node | `containers/base/development-node/Dockerfile` | `containers/base/development-node` |
| development-python | `containers/base/development-python/Dockerfile` | `containers/base/development-python` |
| development-full | `containers/base/development-full/Dockerfile` | `containers/base/development-full` |
| development-agent | `containers/agent/Dockerfile` | `containers/agent` |

Any `COPY` instruction in a Dockerfile uses a path relative to that image's own directory. Do not write paths that assume the repo root as context; any such path will silently fail to copy the file.

## system-gitconfig and SSH Rewriting

All git operations — both inside the container and on the host — are configured to rewrite `https://github.com/` URLs to `git@github.com:`. This is done at two levels:

**Inside the container:** `containers/base/development-full/system-gitconfig` is baked into the image at `/etc/gitconfig` (root:root 0444). It rewrites HTTPS to SSH for github.com, gitlab.com, and bitbucket.org.

**On the host:** `setup-owner`'s `configure_git()` writes the same `url.insteadOf` / `pushInsteadOf` rules into the owner user's `~/.gitconfig`. Every owner provisioned via `setup-owner --owner <name>` has SSH rewriting active on the host.

Together these mean that even if the agent inside the container changes the remote URL to HTTPS (e.g. via `gh pr checkout`), any subsequent `git push` — whether in the container or on the host — will still use SSH.

As belt-and-suspenders, `ensure_repo_current()` and `try_nonagentic_rebase()` in `oneshot` also explicitly reset the remote URL to `git@github.com:` before each push, fixing the stored URL in `.git/config` for all tools regardless of `url.insteadOf`.

The self-check HTTPS clone in each Dockerfile uses `GIT_CONFIG_SYSTEM=/dev/null` to bypass this rewrite (no SSH key is available at build time).

## Local Build Before Any Change (MANDATORY)

Before making any change to a Dockerfile or its associated workflow, build the affected image locally and confirm it succeeds:

```bash
docker build -t <image-name>:local containers/base/<stage>/
```

Do not commit, push, or raise a PR until the local build passes. A broken image must be caught locally — not by CI.

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

## Pinned Upstream Repo Clones (MANDATORY)

Never clone an external repo with a plain `git clone --depth 1 <url>` and then assert the resulting `HEAD` equals a pinned commit — that clones whatever the default branch's tip is *right now*, so the assertion (and the build) fails every time upstream gets a new commit, not just on an actual tamper event. Pick the mechanism per repo, and re-evaluate the choice (not just the value) whenever bumping:

- **Third-party repo with a current, compatible tagged release**: pin to that tag and verify the commit it resolves to:

  ```dockerfile
  ARG SOME_REF=v1.0.0
  ARG SOME_COMMIT=<sha the tag resolves to>
  RUN git clone --depth 1 --branch "${SOME_REF}" https://github.com/<org>/<repo>.git /opt/tool \
      && test "$(git -C /opt/tool rev-parse HEAD)" = "${SOME_COMMIT}" \
      && chown -R root:root /opt/tool
  ```

  "Compatible" means: check the tag isn't stale relative to what the Dockerfile actually consumes (e.g. a hardcoded file/skill list or count) — diff the tag's relevant subtree against current default-branch HEAD before adopting it. A stale tag that predates a refactor the build depends on is worse than no tag.

- **Third-party repo with no usable tag** (none published, or the latest one is stale/incompatible): pin to an exact commit SHA, fetched directly rather than cloned from the moving tip:

  ```dockerfile
  ARG SOME_COMMIT=<pinned sha>
  RUN git init -q /opt/tool \
      && git -C /opt/tool fetch -q --depth 1 https://github.com/<org>/<repo>.git "${SOME_COMMIT}" \
      && git -C /opt/tool checkout -q FETCH_HEAD \
      && chown -R root:root /opt/tool
  ```

  This only fails the build if that commit becomes unreachable upstream (a force-push/history rewrite) — verified: `git fetch <url> <bogus-sha>` fails hard (`fatal: remote error: upload-pack: not our ref ...`, exit 128), so the tamper-detection property is preserved. For a sparse-checkout repo, run `git sparse-checkout init --cone` before the `fetch` and `sparse-checkout set <paths>` before the `checkout`.

- **credfeto-owned repo**: implicitly trusted — always track live main HEAD with no pinned-commit assertion at all (plain `git clone --depth 1 <url>`, no `test`). Still cache-bust on a live-resolved value (e.g. `git ls-remote <url> HEAD` in the workflow) so the layer refreshes when upstream changes — see `credfeto-global-pre-commit` and `credfeto-ai-skills` in `containers/base/development-full/Dockerfile`.

### Sanity-checking a dynamic set (e.g. skills)

Do not hardcode an exact expected count (`[ "$n" -eq 100 ]`) for anything sourced even partly from a live-tracked or otherwise-growing repo — it silently goes stale and starts failing (or worse, stops meaning anything) the next time that source changes. Instead, record the count computed at the point the set is built, and compare against that recorded value later, with a `-gt 0` guard so a degenerate build that produces zero of everything doesn't trivially "match":

```dockerfile
RUN ...build the set... \
    && find /some/dir -mindepth 1 -maxdepth 1 -type l | wc -l > /opt/.some-count \
    && chown -R root:root /some/dir /opt/.some-count && chmod 0444 /opt/.some-count
# ...later, in the sanity check...
RUN actual=$(find /some/dir -mindepth 1 -maxdepth 1 -type l | wc -l); \
    expected=$(cat /opt/.some-count); \
    [ "$actual" -eq "$expected" ] && [ "$actual" -gt 0 ] || { echo "FATAL: ..." >&2; exit 1; }
```

See the `~/.claude/skills` symlink count in `containers/base/development-full/Dockerfile`.

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
