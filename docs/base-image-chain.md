# How the base image chain works

## The simplest possible explanation

Building a container image is like baking a layer cake: each layer sits on top of the previous
one, and if a layer's ingredients haven't changed, the "bake" for that layer can be skipped and
reused from last time (a "cache hit"). This project builds its final agent image as a chain of
six separate images, each adding one more layer of tools on top of the one before it, so that
changing one thing (say, a linting tool's config) only re-bakes the one layer that actually
needs it, instead of re-baking the whole cake from scratch every time.

## The chain, in order

```text
development-tools → development-node → development-python
    → development-dotnet-tools → development-credfeto-tools → development-full → agent
```

| Stage | Image | Adds |
| --- | --- | --- |
| 1 | `development-tools` | The base OS (`debian:trixie-slim`) plus the full CI/CD and linting toolchain: shellcheck, bats, hadolint, actionlint, and everything else the orchestrator's own pre-commit hooks and the agent's own linting need. |
| 2 | `development-node` | Node.js and the Bun runtime, plus global npm packages. |
| 3 | `development-python` | Python tooling too new or unusual for Debian's own packages (`uv`, `ruff`, a newer `sqlfluff`), installed via pip. |
| 4 | `development-dotnet-tools` | `claude-code` itself, plus the stable, genuinely-third-party (not org-owned) .NET global tools. |
| 5 | `development-credfeto-tools` | The first-party `Credfeto.*`/`FunFair.*` .NET global tools this project actively ships and updates itself. |
| 6 | `development-full` | Everything that isn't a "tool": pinned skill repositories, Claude Code settings/hooks, and the shared pre-commit hook orchestrator. |
| 7 | `agent` (`containers/agent/`) | Locks the whole thing down for unattended use — see [agent-container.md](agent-container.md). |

## Why split it this way at all

Every one of these images is rebuilt automatically whenever something it depends on changes —
but "something changed" means different things for different layers, and lumping them all
together used to mean one thing changing forced *everything* downstream of it to rebuild, even
when nothing about that downstream layer's own content had actually changed:

- Stages 1–3 barely change once set up; they're the OS-and-language-runtime foundation.
- Stage 4's third-party .NET tools ship new versions on their own schedule, entirely outside this
  project's control.
- Stage 5's first-party tools ship new versions whenever *this org* decides to release one —
  independently of stage 4's third-party tools.
- Stage 6's skill repos and pre-commit orchestrator genuinely change often (they float to the
  live upstream `main` branch of their own separate repos), but have nothing to do with which
  .NET tools are installed.

Splitting stages 4 and 5 apart, and splitting both away from stage 6, means a first-party tool
release never busts the third-party layer's cache and vice versa, and neither ever busts the
skills/hooks layer's cache. Each layer only pays the cost of rebuilding when something it
actually contains has genuinely changed.

## How each layer knows whether it needs to rebuild ("cache-busting")

Every stage's build workflow computes a value that changes only when something real changed for
that specific stage, and passes it into the Docker build as an argument that's baked into the
relevant `RUN` instruction's cache key — if the value is identical to last time, Docker reuses
the cached layer instead of re-running the install:

- Stages 4 and 5 (the .NET tool layers) query the NuGet registry for the latest published
  version of each tool they install, and hash those versions together. A new tool release
  changes the hash; nothing changing keeps it identical and the layer is a fast cache hit.
- Stage 6 (`development-full`)'s skill repos and pre-commit orchestrator are cache-busted by the
  resolved commit SHA of whichever upstream repo they float to — same idea, applied to git
  instead of NuGet.

This is deliberately the same *shape* of mechanism as fingerprinting (see
[fingerprinting.md](fingerprinting.md)): "did the thing that actually matters change, not just
did some incidental detail change" — just applied to container image layers instead of GitHub
Issues and Pull Requests.

## Assumptions

- Each stage's own build-time sanity check (a `RUN` step near the end of its Dockerfile that
  probes every tool it just installed) is trusted to catch a broken install at build time,
  before that broken layer ever gets published and pulled by a real run.
- A tool that's only ever verified in an *earlier* stage doesn't need re-verifying in every
  later stage that inherits it — each stage's own sanity check only re-verifies what changed for
  that stage, trusting the stages before it.
- The chain is a straight line (each stage has exactly one parent), not a diamond — nothing in
  this project currently needs to combine two independently-built branches of this chain back
  together.
