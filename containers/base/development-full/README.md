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

### Linking skills into `~/.claude/skills`

Claude Code discovers "personal" skills as immediate subdirectories of `~/.claude/skills/`, each
containing a `SKILL.md`. The four repos above nest their skills at different depths, so after cloning,
every individual skill directory is symlinked into `/home/developer/.claude/skills/<name>` (not the repo
roots themselves):

| Repo | Skills subpath | Skill count |
| --- | --- | --- |
| `/opt/dotnet-claude-kit` | `skills/<name>/` | 45 |
| `/opt/wshobson-agents` | `plugins/{javascript-typescript,python-development,shell-scripting}/skills/<name>/` | 23 |
| `/opt/cc-devops-skills` | `devops-skills-plugin/skills/<name>/` | 31 |
| `/opt/markdown-linter-fixer` | `skills/<name>/` | 1 |

The symlinking step is driven by a `find -mindepth 1 -maxdepth 1 -type d` loop over each repo's `skills/`
subtree (not a hardcoded name list), so newly added upstream skills are picked up automatically on the
next build as long as they still land under a `skills/` folder. The build fails if two repos ever produce
a skill with the same name. `/home/developer/.claude/skills/` and every symlink in it are root:root —
`developer` can read/execute through them (to resolve and use the skill) but cannot add, remove, or
retarget entries.

### Baked-in Claude Code settings, policy-limits, and hooks

`containers/base/development-full/claude-settings.json`, `claude-policy-limits.json`, and
`claude-hooks/{enforce-git-dash-c,enforce-git-identity,reject-obfuscated-commands,block-git-worktree}` are version-controlled copies of the operator's
`~/.claude/{settings.json,policy-limits.json,hooks/{enforce-git-dash-c,enforce-git-identity,reject-obfuscated-commands,block-git-worktree}}`, copied into the image at
`/home/developer/.claude/{settings.json,policy-limits.json,hooks/{enforce-git-dash-c,enforce-git-identity,reject-obfuscated-commands,block-git-worktree}}` as root:root
0444 (files) / 0755 (hook scripts and hooks directory) — read-only for `developer`. `reject-obfuscated-commands`
runs first in the `PreToolUse` hook chain, ahead of every other hook, and parses each Bash command with
`shfmt` (a real shell parser, baked into this image) rather than text-scanning: any non-printable or
non-ASCII byte, any command that fails to parse, any command name that is not a single plain literal word
(quote-splices, escapes, substitutions, brace/`${IFS}` expansion), function definitions,
`declare`/`export` clauses, and assignments to variables on `claude-hooks/env-var-blocklist` (IFS, PATH,
LD_*, GIT_*, ...) are all rejected categorically. Surviving command names are then policy-checked against
two data files baked in alongside the hook: names on `claude-hooks/command-blocklist` (eval, sub-shells,
wrapper commands like sudo/env/nice/timeout) are rejected with a per-name message, and anything not on
`claude-hooks/command-allowlist` (known-good tools, matched by basename for path-qualified invocations) is
rejected too — extending policy is a one-line data-file change, not hook logic. Known interpreters
(python3, ...) are additionally refused inline-code flags (`-c`/`-e`/...). `enforce-git-dash-c` uses the
same shfmt-parsed AST and blocks git commands that don't use `git -C <dir>` (plus `eval`/`source`, whose
arguments it cannot verify); both hooks fail closed if shfmt is missing or the command does not parse.
`enforce-git-identity` blocks `git commit`/`fetch`/`pull`/`rebase`/`merge`/`cherry-pick`/`revert`/`am` unless
git identity and GPG signing are correctly configured, and runs before `enforce-git-dash-c` in the chain.
`block-git-worktree` runs last, after `enforce-git-dash-c`, and uses the same shfmt-parsed AST to block
`git worktree add` (creating a new linked worktree; `list`/`remove`/`prune`/... stay allowed) — a linked
worktree splits repo state across multiple checkouts sharing one object store, which has previously left
a primary checkout registered as bare with no work tree of its own; it also fails closed if shfmt is
missing or the command does not parse.
All hook paths referenced from `settings.json`'s `PreToolUse` block are rewritten to the in-container path
(`/home/developer/.claude/hooks/reject-obfuscated-commands`, `/home/developer/.claude/hooks/enforce-git-dash-c`,
`/home/developer/.claude/hooks/enforce-git-identity`, and `/home/developer/.claude/hooks/block-git-worktree`).
`oneshot` does not bind-mount over any of these
paths at runtime (see `containers/agent/Dockerfile` for the full mount contract) — only `CLAUDE.md` and
the persistent state subdirectories (`sessions/`, `session-env/`, `plans/`, `cache/`, `backups/`) are
mounted per invocation.

The repo-root `install-claude-hooks` script installs this same settings.json and hook set into the
current host user's `~/.claude`, so the hooks can be exercised directly outside the container: hook/data
files are symlinked straight back into this repo, and settings.json is regenerated from the container's
copy with every `/home/developer/.claude` path rewritten to the host's own `$HOME/.claude`. It refuses to
run inside a live Claude Code session (it would be rewriting the very hooks/settings governing that
session mid-run) — run it from a plain host shell.

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
| `/opt/dotnet-claude-kit/` | root:root | 0755 | Claude Code .NET plugin side; agent can read/execute but not modify |
| `/opt/wshobson-agents/` | root:root | 0755 | Sparse-checkout of javascript-typescript, python-development, shell-scripting plugins; agent can read/execute but not modify |
| `/opt/cc-devops-skills/` | root:root | 0755 | GitHub Actions devops skills plugin; agent can read/execute but not modify |
| `/opt/markdown-linter-fixer/` | root:root | 0755 | Markdown linter/fixer skill (pinned to `MARKDOWN_LINTER_FIXER_REF`); agent can read/execute but not modify |
| `/home/developer/.claude/skills/` | root:root | 0755 | 100 symlinks into the `/opt/*` skill repos above, one per skill; agent can read/execute but not add, remove, or retarget |
| `/home/developer/.claude/settings.json` | root:root | 0444 | Baked-in Claude Code settings (from `claude-settings.json`); read-only for all users |
| `/home/developer/.claude/policy-limits.json` | root:root | 0444 | Baked-in Claude Code policy limits (from `claude-policy-limits.json`); read-only for all users |
| `/home/developer/.claude/hooks/` | root:root | 0755 | Baked-in Claude Code hooks directory; agent can read/execute but not modify |
| `/home/developer/.claude/hooks/enforce-git-dash-c` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-git-dash-c`); read/execute only |
| `/home/developer/.claude/hooks/enforce-git-identity` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-git-identity`); read/execute only |
| `/home/developer/.claude/hooks/reject-obfuscated-commands` | root:root | 0755 | Baked-in hook script (from `claude-hooks/reject-obfuscated-commands`); read/execute only |
| `/home/developer/.claude/hooks/block-git-worktree` | root:root | 0755 | Baked-in hook script (from `claude-hooks/block-git-worktree`); read/execute only |
| `/home/developer/.claude/hooks/command-allowlist` | root:root | 0444 | Known-good command names for `reject-obfuscated-commands` (from `claude-hooks/command-allowlist`); read-only |
| `/home/developer/.claude/hooks/command-blocklist` | root:root | 0444 | Known-bad command names for `reject-obfuscated-commands` (from `claude-hooks/command-blocklist`); read-only |
| `/home/developer/.claude/hooks/env-var-blocklist` | root:root | 0444 | Banned environment-variable assignments for `reject-obfuscated-commands` (from `claude-hooks/env-var-blocklist`); read-only |
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

**Claude Code settings/policy-limits/hooks wiring** — `/home/developer/.claude/settings.json` and
`.../policy-limits.json` must be root:root 0444; `.../hooks/enforce-git-dash-c`,
`.../hooks/enforce-git-identity`, `.../hooks/reject-obfuscated-commands`, and `.../hooks/block-git-worktree`
must each be root:root 0755 and executable; the `.../hooks/{command-allowlist,command-blocklist,env-var-blocklist}`
policy data files must each be root:root 0444.

**Claude Code skills wiring** — exactly 100 symlinks must exist directly under
`/home/developer/.claude/skills/`; a spot-check of representative skill names (one per source repo,
e.g. `markdown-linter-fixer`, `tdd`, `k8s-debug`, `python-type-safety`, `bash-defensive-patterns`,
`terraform-validator`) must each resolve to a directory containing `SKILL.md`.

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
