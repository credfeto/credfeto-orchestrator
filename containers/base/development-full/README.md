# development-full

Base image: `ghcr.io/credfeto/development-python:latest`

This image layers .NET global tools, a locked-down NuGet configuration, a curated set of Claude Code skill repositories, and a tamper-resistant global pre-commit hook chain on top of the base Python development image.

---

## What it installs

### NuGet.Config for FunFair feeds

A `NuGet.Config` is baked into the image at `/home/developer/.nuget/NuGet/NuGet.Config`. It clears the default NuGet source and registers three FunFair-specific caching proxies:

- `Cache: api.nuget.org` — `https://api-nuget.markridgwell.com/v3/index.json`
- `Cache: FunFair` — `https://funfair-nuget.markridgwell.com/index.json`
- `Cache: FunFair (Prerelease)` — `https://funfair-prerelease-nuget.markridgwell.com/index.json`

The package restore cache is redirected to `/home/developer/.nuget-cache` (developer-owned) via `NUGET_PACKAGES` so that `dotnet restore` and `dotnet tool install -g` remain writable without touching the locked config subtree.

### .NET global tools

All twelve tools are installed into the `developer` user's global tool path (`/home/developer/.dotnet/tools`) via `su developer -c "dotnet tool install -g ..."`. Each tool gets its own layer to keep individual blob sizes manageable and to avoid cascading cache invalidation.

| Package ID | Command(s) |
| --- | --- |
| `Credfeto.Changelog.Cmd` | `changelog`, `dotnet-changelog` |
| `Credfeto.DotNet.Code.Analysis.Overrides.Cmd` | `code-analysis`, `dotnet-code-analysis` |
| `TSQLLint` | `tsqllint`, `dotnet-tsqllint` |
| `FunFair.BuildCheck` | `buildcheck`, `dotnet-buildcheck` |
| `FunFair.BuildVersion` | `buildversion`, `dotnet-buildversion` |
| `CWM.RoslynNavigator` | `cwm-roslyn-navigator`, `dotnet-cwm-roslyn-navigator` |
| `dotnet-ef` | `dotnet-ef` |
| `ilspycmd` | `ilspycmd`, `dotnet-ilspycmd` |
| `Microsoft.SqlPackage` | `sqlpackage`, `dotnet-sqlpackage` |
| `PowerShell` | `pwsh` |
| `Credfeto.DotNet.Repo.Formatter` | `cscleanup`, `dotnet-cscleanup` |
| `dotnet-script` | `dotnet-script` |

`dotnet <name>` subcommand aliases (e.g. `dotnet-buildcheck`) are created via `ln -sf` so that the dotnet CLI can locate tools invoked through subcommand syntax.

### Skill repos cloned

| Destination | Source | Notes |
| --- | --- | --- |
| `/opt/dotnet-claude-kit` | `github.com/codewithmukesh/dotnet-claude-kit` | Full shallow clone; developer:developer ownership |
| `/opt/wshobson-agents` | `github.com/wshobson/agents` | Sparse checkout of three plugins only: `plugins/javascript-typescript`, `plugins/python-development`, `plugins/shell-scripting`; developer:developer ownership |
| `/opt/cc-devops-skills` | `github.com/akin-ozer/cc-devops-skills` | Full shallow clone; developer:developer ownership |
| `/opt/markdown-linter-fixer` | `github.com/s2005/markdown-linter-fixer-skill` | Shallow clone pinned to the tag in `MARKDOWN_LINTER_FIXER_REF` (default `v1.5.4`); developer:developer ownership |

### credfeto-global-pre-commit clone

The upstream hook orchestrator is cloned from `$PRECOMMIT_UPSTREAM` (default: `https://github.com/credfeto/credfeto-global-pre-commit.git`) into `/opt/pre-commit`. After cloning:

- The `.git`, `.github`, `.ai-instructions`, `ai`, and `CLAUDE.md` directories/files are removed.
- The HEAD SHA is recorded in `/opt/pre-commit/.env` (`SHA=<sha>`) for provenance.
- The build asserts that `src/.pre-commit-config.yaml` exists; the build fails if it has been renamed or deleted upstream.

### Global hooks shim

`/opt/git-global-hooks/pre-commit` is a one-line shim that delegates to `/opt/pre-commit/src/hooks/pre-commit`. This directory is referenced by `core.hooksPath` in the system-wide gitconfig so that every repository the agent works in runs the full pre-commit chain automatically.

### System-wide gitconfig

`/etc/gitconfig` is copied from `system-gitconfig` in the build context and set to root:root mode 0444. Git validates the file at build time (`git config --file /etc/gitconfig --list`). A `/usr/bin/gpg2` symlink is created pointing to `/usr/bin/gpg` for compatibility with gitconfigs that pin `gpg.program=/usr/bin/gpg2`.

---

## Users

The `developer` user is inherited from upstream images in the `development-tools` / `development-python` chain.

- `/home/developer/.nuget/` and `/home/developer/.nuget/NuGet/` are root:root 0755 — the `developer` user can traverse them but cannot rename, remove, or swap out files.
- `/home/developer/.nuget/NuGet/NuGet.Config` is root:root 0444 — readable but immutable by the agent.
- `/home/developer/.nuget-cache/` is developer:developer — writable package restore cache.
- All `dotnet tool install -g` commands are run as `developer` via `su developer -c "..."` so that the tools land in the correct per-user profile and are executable by the agent at runtime.

---

## Locked-down paths

| Path | Owner | Mode | Purpose |
| --- | --- | --- | --- |
| `/home/developer/.nuget/` | root:root | 0755 | Parent of the config subtree; not writable by developer |
| `/home/developer/.nuget/NuGet/` | root:root | 0755 | Contains NuGet.Config; not writable by developer |
| `/home/developer/.nuget/NuGet/NuGet.Config` | root:root | 0444 | Baked-in NuGet feed list; read-only for all users |
| `/home/developer/.nuget-cache/` | developer:developer | (default) | Writable package restore cache redirected via `NUGET_PACKAGES` |
| `/opt/pre-commit/` | root:root | 0755 | Global pre-commit orchestrator; readable and executable, not writable |
| `/opt/git-global-hooks/` | root:root | 0755 | Global hooks shim directory; executable, not writable |
| `/opt/git-global-hooks/pre-commit` | root:root | 0755 | Shim that delegates to `/opt/pre-commit/src/hooks/pre-commit` |
| `/etc/gitconfig` | root:root | 0444 | System-wide git configuration; immutable at runtime |
| `/opt/dotnet-claude-kit/` | developer:developer | (default) | Claude Code plugin repo; writable by developer |
| `/opt/wshobson-agents/` | developer:developer | (default) | Sparse-checked-out agent plugin repo; writable by developer |
| `/opt/cc-devops-skills/` | developer:developer | (default) | DevOps skills repo; writable by developer |
| `/opt/markdown-linter-fixer/` | developer:developer | (default) | Markdown linter skill repo; writable by developer |
| `/opt/composite-action-lint` | root:root | (installed by upstream) | Composite action linter binary from upstream image |

---

## Self-checks

The build runs two distinct verification stages.

### Stage 1 — build-time sanity check

Executed as root. Fails the build immediately if anything is missing or broken.

**Binary presence and `--version` probe** — all of the following must be on `PATH` and exit 0 for `--version`:

`git`, `gh`, `dotnet`, `python3`, `gpg`, `curl`, `sqlite3`, `shellcheck`, `bats`, `shfmt`, `checkbashisms`, `uv`, `ruff`, `sqlfluff`, `actionlint`, `markdownlint-cli2`, `pre-commit`, `trufflehog`, `hadolint`, `dotenv-linter`, `sqlcmd`, `composite-action-lint`, `pwsh`, `yamllint`, `ansible-lint`, `flake8`, `pylint`, `cfn-lint`, `markdownlint`, `stylelint`, `eslint`, `xmllint`

**dotnet global tool verification** — `dotnet tool list -g` is run as `developer` and each of the following package IDs must appear (case-insensitive):

`credfeto.changelog.cmd`, `credfeto.dotnet.code.analysis.overrides.cmd`, `tsqllint`, `funfair.buildcheck`, `funfair.buildversion`, `cwm.roslynnavigator`, `dotnet-ef`, `ilspycmd`, `microsoft.sqlpackage`, `powershell`, `credfeto.dotnet.repo.formatter`, `dotnet-script`

**cwm-roslyn-navigator functional probe** — `cwm-roslyn-navigator --help` is run as `developer` and must exit 0.

**gpg self-check** — `echo "probe" | gpg --dearmor` is piped and must not error (or `gpg --version` must exit 0 as a fallback).

**sqlite3 self-check** — `sqlite3 :memory: "SELECT 1;"` must return `1`.

**HTTPS clone** — a sacrificial public repository (`github.com/dnyw4l3n13/scratch`) is cloned over HTTPS with `GIT_CONFIG_SYSTEM=/dev/null` to verify outbound TLS connectivity. The clone is removed immediately after.

**pre-commit wiring checks**:

- `/opt/pre-commit/.env` must exist.
- `/opt/pre-commit/src/.pre-commit-config.yaml` must exist.
- `/opt/git-global-hooks/pre-commit` must be executable.

### Stage 2 — acceptance test suite

After the sanity check passes, the upstream acceptance test suite (`/opt/pre-commit/acceptance-test`) is run as the `developer` user against the installed hook chain:

1. `/opt/pre-commit` is copied to `/tmp/pre-commit-test` and its ownership is set to developer:developer.
2. `/tmp/pre-commit-test/.env` is removed so the orchestrator's network-dependent freshness check is skipped (non-freshness tests still run).
3. `su developer -c /tmp/pre-commit-test/acceptance-test` is executed.
4. The temporary copy is removed.

The build fails if the acceptance suite exits non-zero.

---

## Suggestions for further lock-down

- **`chattr +i` on NuGet.Config** — if the host kernel supports it and the build tooling does not object, setting the immutable attribute (`chattr +i /home/developer/.nuget/NuGet/NuGet.Config`) prevents even root from removing or overwriting the file at runtime without explicitly clearing the attribute first. This is an additional defence in depth on top of the 0444 mode.

- **Separate `$HOME` for agent vs. tooling** — the agent process and the .NET tools currently share `/home/developer`. Giving the agent process a distinct home directory (e.g. `/home/agent`) while keeping .NET tools under `/home/developer` would further reduce the blast radius if the agent gains unexpected write access in its own home.

- **Read-only filesystem mounts for `/opt/*` at runtime** — directories such as `/opt/pre-commit`, `/opt/git-global-hooks`, `/opt/cc-devops-skills`, and `/opt/dotnet-claude-kit` could be bind-mounted read-only at container startup (`--mount type=bind,source=...,target=...,readonly` or a `tmpfs` overlay). This prevents runtime tampering even if a process escalates to root inside the container.
