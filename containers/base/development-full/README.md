# development-full

Base image: `ghcr.io/credfeto/development-credfeto-tools:latest`

This is stage 6 of the development base image chain:

```text
development-tools  →  development-node  →  development-python
    →  development-dotnet-tools  →  development-credfeto-tools  →  development-full
```

It layers a curated set of Claude Code skill repositories, the `credfeto-ai-skills`
Claude Code agents, baked-in Claude Code settings/hooks, and a tamper-resistant
global pre-commit hook chain on top of `development-credfeto-tools`. The NuGet
configuration, `claude-code`, and all twelve .NET global tools (both stable
third-party and first-party Credfeto.*/FunFair.*) are inherited from
`development-dotnet-tools` / `development-credfeto-tools`. See those images' own
READMEs for what they install and why they're split out.

---

## What it installs

### Skill repos cloned

| Destination | Source | Notes |
| --- | --- | --- |
| `/opt/dotnet-claude-kit` | `github.com/codewithmukesh/dotnet-claude-kit` | Full shallow clone; developer:developer ownership |
| `/opt/wshobson-agents` | `github.com/wshobson/agents` | Sparse checkout of three plugins only: `plugins/javascript-typescript`, `plugins/python-development`, `plugins/shell-scripting`; developer:developer ownership |
| `/opt/cc-devops-skills` | `github.com/akin-ozer/cc-devops-skills` | Full shallow clone; developer:developer ownership |
| `/opt/markdown-linter-fixer` | `github.com/s2005/markdown-linter-fixer-skill` | Shallow clone pinned to the tag in `MARKDOWN_LINTER_FIXER_REF` (default `v1.5.4`); developer:developer ownership |
| `/opt/dotnet-skills` | `github.com/dotnet/skills` | Sparse checkout of seven plugins only: `plugins/dotnet`, `plugins/dotnet-advanced`, `plugins/dotnet-diag`, `plugins/dotnet-msbuild`, `plugins/dotnet-nuget`, `plugins/dotnet-test`, `plugins/dotnet-upgrade`; pinned to `DOTNET_SKILLS_COMMIT` (no usable tag, see pin-policy comment in the Dockerfile); root:root ownership |

### Linking skills into `~/.claude/skills`

Claude Code discovers "personal" skills as immediate subdirectories of `~/.claude/skills/`, each
containing a `SKILL.md`. The repos above nest their skills at different depths, so after cloning,
every individual skill directory is symlinked into `/home/developer/.claude/skills/<name>` (not the repo
roots themselves):

| Repo | Skills subpath | Skill count |
| --- | --- | --- |
| `/opt/dotnet-claude-kit` | `skills/<name>/` | 45 |
| `/opt/wshobson-agents` | `plugins/{javascript-typescript,python-development,shell-scripting}/skills/<name>/` | 23 |
| `/opt/cc-devops-skills` | `devops-skills-plugin/skills/<name>/` | 31 |
| `/opt/markdown-linter-fixer` | `skills/<name>/` | 1 |
| `/opt/dotnet-skills` | `plugins/{dotnet,dotnet-advanced,dotnet-diag,dotnet-msbuild,dotnet-nuget,dotnet-test,dotnet-upgrade}/skills/<name>/` | counted dynamically, see Stage 1 sanity check |

The symlinking step is driven by a `find -mindepth 1 -maxdepth 1 -type d` loop over each repo's `skills/`
subtree (not a hardcoded name list), so newly added upstream skills are picked up automatically on the
next build as long as they still land under a `skills/` folder. The build fails if two repos ever produce
a skill with the same name. `/home/developer/.claude/skills/` and every symlink in it are root:root —
`developer` can read/execute through them (to resolve and use the skill) but cannot add, remove, or
retarget entries.

### Linking agents into `~/.claude/agents`

Claude Code discovers "personal" subagents as `*.md` files directly under `~/.claude/agents/`.
`/opt/credfeto-ai-skills` keeps each agent at `ai/agents/<name>/AGENT.md`, next to non-agent files such
as `config.yaml` and `install`. Every `ai/agents/<name>/` subdirectory that contains an `AGENT.md` has
that file symlinked to `/home/developer/.claude/agents/credfeto-<name>.md`; everything else under
`ai/agents/` is ignored. Upstream's `ai/agents/install` script is not run.

The build fails if `ai/agents/` is missing, if any link cannot be created, or if no agents are
linked. The number of links is recorded in `/opt/.claude-agent-count`.
`/home/developer/.claude/agents/` and every symlink in it are root:root, so `developer` can read the
agent definitions but cannot add, remove, or retarget entries.

### Baked-in Claude Code settings, policy-limits, and hooks

`containers/base/development-full/claude-user-settings.json`, `claude-policy-limits.json`,
`claude-managed-settings.json`, and
`claude-hooks/{reject-obfuscated-commands,enforce-allowed-dirs,block-config-skills,enforce-git-identity,enforce-git-dash-c,block-git-worktree,block-dotnet-tool-install,block-github-mcp-write-tools,enforce-ssh-host-and-key,enforce-curl-host,enforce-background-for-long-running-commands,cache-gh-lookups,command-allowlist,command-blocklist,env-var-blocklist,allowed-dirs}` are version-controlled,
copied into the image at `/home/developer/.claude/{settings.json,policy-limits.json}` (the preferences
half only) and
`/etc/claude-code/{managed-settings.json,hooks/{reject-obfuscated-commands,enforce-allowed-dirs,block-config-skills,enforce-git-identity,enforce-git-dash-c,block-git-worktree,block-dotnet-tool-install,block-github-mcp-write-tools,enforce-ssh-host-and-key,enforce-curl-host,enforce-background-for-long-running-commands,cache-gh-lookups,command-allowlist,command-blocklist,env-var-blocklist,allowed-dirs}}` as root:root
0444 (files) / 0755 (hook scripts and directories) — read-only for `developer`. Claude Code reads
`/etc/claude-code/managed-settings.json` ahead of every user and project settings file, and its
`allowManagedPermissionRulesOnly`/`allowManagedHooksOnly`/`allowManagedMcpServersOnly` locks stop a repo's
`.claude/settings*.json` adding permissions, hooks or MCP servers. `reject-obfuscated-commands`
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
(python3, ...) are additionally refused inline-code flags (`-c`/`-e`/...). `enforce-allowed-dirs` runs
second, on the already-normalised command: every directory- or path-taking argument of `cd`/`pushd`,
`git -C`, `npm --prefix`, `find` (starting points) and `rm`/`mv`/`cp` (operands) must resolve (symlinks
followed) under one of the roots listed in `claude-hooks/allowed-dirs` (baked root:root 0444 with the
agent container's three mounts, `/workspace/repo`, `/workspace/rules`, `/workspace/tmp`), and the flags
that turn a path argument into code execution (`git --exec-path`/`--git-dir`/`--work-tree`/`--namespace`/
`--super-prefix`, every `git -c` key outside a short allowlist of inert display/behaviour keys,
`npm --script-shell`/`--userconfig`/`--globalconfig`, `find -exec`/`-execdir`/`-ok`/`-okdir`/`-delete`/`-D`/`-O`,
`rm --no-preserve-root`) are denied outright. It also holds every path a command writes (the writing
redirections, and the arguments of every command `claude-hooks/command-allowlist` classifies as `writer`;
an unclassified command is blocked) to the same roots and away from Claude Code's own configuration, and
checks Edit/Write/NotebookEdit paths against that configuration. This is
the check `claude-managed-settings.json`'s own rule syntax cannot express (it has only literal text and `*`, so a
`git -C <dir> ...` allow entry needs a `*` in the directory position that also matches any option injected
there, the source of Claude Code's "has a wildcard before the rest of the command" startup warning); with
the hook in place the per-subcommand wildcard entries are gone from `permissions.allow` and the same flags
are also listed in `permissions.deny` as belt-and-braces. See `claude-hooks.instructions.md` for the path
resolution rules and the host-side `allowed-dirs.local` override. `enforce-git-dash-c` uses the
same shfmt-parsed AST and blocks git commands that don't use `git -C <dir>` (plus `eval`/`source`, whose
arguments it cannot verify); both hooks fail closed if shfmt is missing or the command does not parse.
`enforce-git-identity` blocks `git commit`/`fetch`/`pull`/`rebase`/`merge`/`cherry-pick`/`revert`/`am` unless
git identity and GPG signing are correctly configured, and runs before `enforce-git-dash-c` in the chain.
`block-git-worktree` runs after `enforce-git-dash-c`, and uses the same shfmt-parsed AST to block
`git worktree add` (creating a new linked worktree; `list`/`remove`/`prune`/... stay allowed) — a linked
worktree splits repo state across multiple checkouts sharing one object store, which has previously left
a primary checkout registered as bare with no work tree of its own; it also fails closed if shfmt is
missing or the command does not parse. `block-dotnet-tool-install` runs next, using the same shfmt-parsed
AST to block `dotnet tool install` (local or global; `list`/`restore`/`uninstall`/`update`/`run`/... stay
allowed) and `dotnet new tool-manifest` — this container's .NET global tools are pinned and baked into the
image at build time, and either command would add an unpinned, unreviewed tool outside that set; it also
fails closed if shfmt is missing or the command does not parse. `block-github-mcp-write-tools` is
registered against a separate `mcp__github__.*` matcher, not the `Bash` chain above: it reads only
`.tool_name` (there is no command string for an MCP tool call) and blocks the five GitHub MCP tools
that write through the API directly (`create_or_update_file`, `delete_file`, `push_files`,
`merge_pull_request`, `update_pull_request_branch`), since those bypass every local git hook this repo
relies on (pre-commit, commit-msg, pre-push); it fails closed on a missing/empty `tool_name`.
`enforce-ssh-host-and-key` runs next,
restricting `ssh` to a strict `user@host.lan` grammar with a usable key already loaded in the forwarded
ssh-agent, since `claude-managed-settings.json`'s own `Bash(ssh *)` allow entry is otherwise blanket; see
`claude-hooks.instructions.md` for the full grammar/host-allowlist rules. `enforce-background-for-long-running-commands`
runs next, using the same shfmt-parsed AST to block `git commit`, a directly-invoked `pre-commit`,
`pre-commit-check`, `buildtest`, `dotnet build`, `dotnet test`, `npm test`, and `bun test` unless the tool
call sets `run_in_background: true` (a call that omits the field entirely is treated the same as `false`);
these commands have no bounded, predictable duration, and a foreground run that outlives the tool's own timeout is killed mid-run,
skipping the target process's own cleanup; it also fails closed if shfmt is missing or the command does
not parse. `cache-gh-lookups` runs last and, unlike every hook above, never blocks: it rewrites an exact,
whole-command `gh api user --jq '.login'` call into a read of a small persistent cache file instead
(populating it first if it isn't there yet); anything else (a parse failure, missing shfmt, or a
non-matching command) just passes through to the normal permission check.
Every hook command in `managed-settings.json`'s `PreToolUse` block is an absolute
`/etc/claude-code/hooks/<name>` path (`/etc/claude-code/hooks/reject-obfuscated-commands`,
`/etc/claude-code/hooks/enforce-allowed-dirs`, `/etc/claude-code/hooks/block-config-skills`,
`/etc/claude-code/hooks/enforce-git-identity`, `/etc/claude-code/hooks/enforce-git-dash-c`,
`/etc/claude-code/hooks/block-git-worktree`, `/etc/claude-code/hooks/block-dotnet-tool-install`,
`/etc/claude-code/hooks/block-github-mcp-write-tools`, `/etc/claude-code/hooks/enforce-ssh-host-and-key`,
`/etc/claude-code/hooks/enforce-curl-host`,
`/etc/claude-code/hooks/enforce-background-for-long-running-commands`, and
`/etc/claude-code/hooks/cache-gh-lookups`), apart from the `block-no-verify` entry, so the same
root-owned copies run in the container and on a host set up with `install-claude-hooks` below. The
Dockerfile's own build-time sanity check fails the build if any hook command is anything else.
`oneshot` does not bind-mount over any of these
paths at runtime (see `containers/agent/Dockerfile` for the full mount contract) — only `CLAUDE.md` and
the persistent state subdirectories (`sessions/`, `session-env/`, `plans/`, `cache/`, `backups/`) and the
per-work-item transcript directory (`projects/`) are mounted per invocation.

The repo-root `install-claude-hooks` script installs this same layout onto the current host, so the
hooks can be exercised directly outside the container: the managed settings and every hook/data file are
copied root-owned into `/etc/claude-code` with `sudo install` (a copy, so re-run the script after a hook
changes; `CLAUDE_MANAGED_DIR` overrides the directory for tests only), the preferences from
`claude-user-settings.json` are copied to `~/.claude/settings.json` (keeping the previous file as
`settings.json.bak`), and any `~/.claude/hooks` symlinks left pointing into this checkout are removed. An
optional first argument names a file of host directory roots, installed as the root-owned
`/etc/claude-code/hooks/allowed-dirs.local`. It also installs the `cfwf`
helper into `/usr/local/bin` (`CFWF_BIN_DIR` overrides the directory) so anyone on the host can run it
(a copy, not a symlink, so re-run the script after `cfwf` changes),
falling back to `sudo install` if the plain install fails (typically because that directory is not writable), and it aborts before changing
anything if a tool the hooks depend on (`jq`, `shfmt`, `base64`, `realpath`, `git`, `gpg`, `ssh-add`, `sed`,
`grep`) is missing, since a hook whose tool is missing blocks every command. It refuses to
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

### Repo-local scripts (`scripts/`)

Standalone scripts maintained in this repo (`containers/base/development-full/scripts/`) are copied to `/usr/local/bin/`, root:root mode 0755, alongside every other custom binary this image bakes in (`agent-entrypoint`, `sqlcmd`, `composite-action-lint`). Named `scripts/` rather than `bin/` because the repo-root `.gitignore` has a blanket `[Bb]in/` rule for build output that would otherwise silently exclude it:

- `pre-commit-check`: runs the active `pre-commit` hook chain with `--all-files` against the current checkout. See [pre-commit-check](../../../docs/development/scripts/pre-commit-check.md).
- `querydb`: runs `sqlcmd` with the connection settings from `.database` files. See [querydb](../../../docs/development/scripts/querydb.md).
- `cfwf` (Credfeto WorkFlow): one flat command for each recurring multi-step `gh` pattern, such as moving an item on the Workflow board, creating an issue, reading an issue's details or whether its plan has been answered, reading a repository's default branch, visibility, allowed merge methods and description (`cfwf repo view`), listing its collaborators and their roles (`cfwf repo collaborators`), probing the authenticated login, the host and the `gh` version without ever printing a token (`cfwf auth status`), adding a comment to a PR or an issue, judging the checks on a PR's head (with exit codes that keep a failed check apart from a failed read), reading a PR's state and metadata as fixed `key<TAB>value` lines (`cfwf pr view`, with no `--json` or `--jq`), listing a repository's open pull requests (`cfwf pr list`), listing a repository's open issues by priority (`cfwf issue list`), searching one repository's issues (`cfwf issue search`), creating a draft pull request and putting it on the Workflow board as Development in one step, or getting the existing one when the branch already has one (`cfwf pr create`), reading a pull request's comments, reviews and review threads (`cfwf pr comments`), replying to an inline review comment (`cfwf pr reply`), or looking up a repository's latest release (`cfwf release view`), its releases (`cfwf release list`) or the commit a tag points to (`cfwf tag view`), as when pinning a GitHub Action, or listing the status checks a branch requires, from its protection and rulesets (`cfwf branch required-checks`), and checks every body, title and label it posts for leaks (tokens, host paths, private repository names) first, and that an issue title in a repository owned by `credfeto` or `funfair-tech` has the shape `prefix: text` or `prefix(name): text` with a lower-case prefix. See [cfwf](../../../docs/development/scripts/cfwf.md).

Every name is registered on `claude-hooks/command-allowlist` and `claude-managed-settings.json`'s `permissions.allow` (`command-allowlist-parity.bats` keeps those two in step), and `pre-commit-check` is one of the commands `enforce-background-for-long-running-commands` requires `run_in_background: true` for (its `pre-commit` run has the same unbounded duration as invoking `pre-commit` directly) — see `claude-hooks.instructions.md`.

---

## Users

The `developer` user, the NuGet configuration, and the .NET global tools are all inherited from
the `development-tools` / `development-python` / `development-dotnet-tools` / `development-credfeto-tools`
chain — see those images' own READMEs for details. All `dotnet tool install -g` commands upstream
are run as `developer` via `su developer -c "..."` so that the tools land in the correct per-user
profile and are executable by the agent at runtime.

---

## Locked-down paths

Paths locked down by this image. NuGet.Config and the .NET tool paths are locked down by
`development-dotnet-tools` / `development-credfeto-tools` instead — see those images' READMEs.

| Path | Owner | Mode | Purpose |
| --- | --- | --- | --- |
| `/opt/pre-commit/` | root:root | 0755 | Global pre-commit orchestrator; readable and executable, not writable |
| `/opt/git-global-hooks/` | root:root | 0755 | Global hooks shim directory; executable, not writable |
| `/opt/git-global-hooks/pre-commit` | root:root | 0755 | Shim that delegates to `/opt/pre-commit/src/hooks/pre-commit` |
| `/etc/gitconfig` | root:root | 0444 | System-wide git configuration; immutable at runtime |
| `/opt/dotnet-claude-kit/` | root:root | 0755 | Claude Code .NET plugin side; agent can read/execute but not modify |
| `/opt/wshobson-agents/` | root:root | 0755 | Sparse-checkout of javascript-typescript, python-development, shell-scripting plugins; agent can read/execute but not modify |
| `/opt/cc-devops-skills/` | root:root | 0755 | GitHub Actions devops skills plugin; agent can read/execute but not modify |
| `/opt/markdown-linter-fixer/` | root:root | 0755 | Markdown linter/fixer skill (pinned to `MARKDOWN_LINTER_FIXER_REF`); agent can read/execute but not modify |
| `/opt/dotnet-skills/` | root:root | 0755 | Sparse-checkout of dotnet, dotnet-advanced, dotnet-diag, dotnet-msbuild, dotnet-nuget, dotnet-test, dotnet-upgrade plugins (pinned to `DOTNET_SKILLS_COMMIT`); agent can read/execute but not modify |
| `/home/developer/.claude/skills/` | root:root | 0755 | Symlinks into the `/opt/*` skill repos above, one per skill (count recorded at build time in `/opt/.claude-skill-count`); agent can read/execute but not add, remove, or retarget |
| `/home/developer/.claude/agents/` | root:root | 0755 | Symlinks named `credfeto-<name>.md` to each `/opt/credfeto-ai-skills/ai/agents/<name>/AGENT.md` (count recorded at build time in `/opt/.claude-agent-count`); agent can read but not add, remove, or retarget |
| `/home/developer/.claude/settings.json` | root:root | 0444 | Baked-in Claude Code preferences (from `claude-user-settings.json`); read-only for all users |
| `/home/developer/.claude/policy-limits.json` | root:root | 0444 | Baked-in Claude Code policy limits (from `claude-policy-limits.json`); read-only for all users |
| `/etc/claude-code/` | root:root | 0755 | Claude Code managed settings directory; agent can read but not modify |
| `/etc/claude-code/managed-settings.json` | root:root | 0444 | Baked-in Claude Code managed settings: permissions, hooks, sandbox (from `claude-managed-settings.json`); read-only for all users |
| `/etc/claude-code/hooks/` | root:root | 0755 | Baked-in Claude Code hooks directory; agent can read/execute but not modify |
| `/etc/claude-code/hooks/reject-obfuscated-commands` | root:root | 0755 | Baked-in hook script (from `claude-hooks/reject-obfuscated-commands`); read/execute only |
| `/etc/claude-code/hooks/enforce-allowed-dirs` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-allowed-dirs`); read/execute only |
| `/etc/claude-code/hooks/block-config-skills` | root:root | 0755 | Baked-in hook script (from `claude-hooks/block-config-skills`); read/execute only |
| `/etc/claude-code/hooks/enforce-git-identity` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-git-identity`); read/execute only |
| `/etc/claude-code/hooks/enforce-git-dash-c` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-git-dash-c`); read/execute only |
| `/etc/claude-code/hooks/block-git-worktree` | root:root | 0755 | Baked-in hook script (from `claude-hooks/block-git-worktree`); read/execute only |
| `/etc/claude-code/hooks/block-dotnet-tool-install` | root:root | 0755 | Baked-in hook script (from `claude-hooks/block-dotnet-tool-install`); read/execute only |
| `/etc/claude-code/hooks/block-github-mcp-write-tools` | root:root | 0755 | Baked-in hook script (from `claude-hooks/block-github-mcp-write-tools`); read/execute only |
| `/etc/claude-code/hooks/enforce-ssh-host-and-key` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-ssh-host-and-key`); read/execute only |
| `/etc/claude-code/hooks/enforce-curl-host` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-curl-host`); read/execute only |
| `/etc/claude-code/hooks/enforce-background-for-long-running-commands` | root:root | 0755 | Baked-in hook script (from `claude-hooks/enforce-background-for-long-running-commands`); read/execute only |
| `/etc/claude-code/hooks/cache-gh-lookups` | root:root | 0755 | Baked-in hook script (from `claude-hooks/cache-gh-lookups`); read/execute only |
| `/etc/claude-code/hooks/command-allowlist` | root:root | 0444 | Known-good command names for `reject-obfuscated-commands` (from `claude-hooks/command-allowlist`); read-only |
| `/etc/claude-code/hooks/command-blocklist` | root:root | 0444 | Known-bad command names for `reject-obfuscated-commands` (from `claude-hooks/command-blocklist`); read-only |
| `/etc/claude-code/hooks/env-var-blocklist` | root:root | 0444 | Banned environment-variable assignments for `reject-obfuscated-commands` (from `claude-hooks/env-var-blocklist`); read-only |
| `/etc/claude-code/hooks/allowed-dirs` | root:root | 0444 | Allowed directory roots for `enforce-allowed-dirs` (from `claude-hooks/allowed-dirs`); read-only |
| `/opt/composite-action-lint` | root:root | (installed by upstream) | Composite action linter binary from upstream image |
| `/usr/local/bin/pre-commit-check` | root:root | 0755 | Repo-local wrapper script (from `scripts/pre-commit-check`); read/execute only |
| `/usr/local/bin/querydb` | root:root | 0755 | Repo-local wrapper script (from `scripts/querydb`); read/execute only |
| `/usr/local/bin/cfwf` | root:root | 0755 | Repo-local workflow helper (from `scripts/cfwf`); read/execute only |

---

## Self-checks

The build runs two distinct verification stages.

### Stage 1 — build-time sanity check

Executed as root. Fails the build immediately if anything is missing or broken.

**Binary presence and `--version` probe** — all of the following must be on `PATH` and exit 0 for `--version`:

`git`, `gh`, `dotnet`, `python3`, `gpg`, `curl`, `sqlite3`, `shellcheck`, `bats`, `shfmt`, `checkbashisms`, `uv`, `ruff`, `sqlfluff`, `actionlint`, `markdownlint-cli2`, `pre-commit`, `trufflehog`, `hadolint`, `dotenv-linter`, `sqlcmd`, `composite-action-lint`, `pwsh`, `yamllint`, `ansible-lint`, `flake8`, `pylint`, `cfn-lint`, `markdownlint`, `stylelint`, `eslint`, `xmllint`

**dotnet global tool verification** — `dotnet tool list -g` is run as `developer` and each of the following package IDs must appear (case-insensitive):

`credfeto.changelog.cmd`, `credfeto.dotnet.code.analysis.overrides.cmd`, `tsqllint`, `funfair.buildcheck`, `funfair.buildversion`, `cwm.roslynnavigator`, `dotnet-ef`, `ilspycmd`, `microsoft.sqlpackage`, `powershell`, `credfeto.dotnet.repo.formatter`, `dotnet-script`, `dotnet-reportgenerator-globaltool`

**cwm-roslyn-navigator functional probe** — `cwm-roslyn-navigator --help` is run as `developer` and must exit 0.

**gpg self-check** — `echo "probe" | gpg --dearmor` is piped and must not error (or `gpg --version` must exit 0 as a fallback).

**sqlite3 self-check** — `sqlite3 :memory: "SELECT 1;"` must return `1`.

**Repo-local `scripts/` scripts** — `pre-commit-check`, `querydb` and `cfwf` support no `--version` probe, so `/usr/local/bin/pre-commit-check`, `/usr/local/bin/querydb` and `/usr/local/bin/cfwf` are instead checked for presence and the executable bit only.

**HTTPS clone** — a sacrificial public repository (`github.com/dnyw4l3n13/scratch`) is cloned over HTTPS with `GIT_CONFIG_SYSTEM=/dev/null` to verify outbound TLS connectivity. The clone is removed immediately after.

**pre-commit wiring checks**:

- `/opt/pre-commit/.env` must exist.
- `/opt/pre-commit/src/.pre-commit-config.yaml` must exist.
- `/opt/git-global-hooks/pre-commit` must be executable.

**Claude Code settings/policy-limits/hooks wiring** — `/home/developer/.claude/settings.json`,
`/home/developer/.claude/policy-limits.json` and `/etc/claude-code/managed-settings.json` must be root:root
0444, and `/etc/claude-code` and `/etc/claude-code/hooks` root:root 0755; `managed-settings.json` must set
the `allowManaged*Only` locks and disable bypass-permissions mode, `~/.claude/settings.json` must hold no
permissions, hooks, sandbox or MCP configuration, and every `PreToolUse` hook command must be
`block-no-verify` or under `/etc/claude-code/hooks/`; `/etc/claude-code/hooks/reject-obfuscated-commands`,
`.../enforce-allowed-dirs`, `.../block-config-skills`, `.../enforce-git-identity`, `.../enforce-git-dash-c`,
`.../block-git-worktree`, `.../block-dotnet-tool-install`, `.../block-github-mcp-write-tools`,
`.../enforce-ssh-host-and-key`, `.../enforce-curl-host`, `.../enforce-background-for-long-running-commands`,
and `.../cache-gh-lookups` must each be root:root 0755; the
`/etc/claude-code/hooks/{command-allowlist,command-blocklist,env-var-blocklist,allowed-dirs}` policy data
files must each be root:root 0444, `allowed-dirs` must list the three agent mounts, and no
`allowed-dirs.local` may be baked in.

**Claude Code skills wiring**: the number of symlinks recorded at build time in
`/opt/.claude-skill-count` must exist directly under `/home/developer/.claude/skills/`; a spot-check of
representative skill names (one per source repo, e.g. `markdown-linter-fixer`, `tdd`, `k8s-debug`,
`python-type-safety`, `bash-defensive-patterns`, `terraform-validator`, `analyzing-dotnet-performance`)
must each resolve to a directory containing `SKILL.md`.

**Claude Code agents wiring**: the number of symlinks recorded at build time in
`/opt/.claude-agent-count` must exist directly under `/home/developer/.claude/agents/` and be greater
than zero; every `*.md` link there must resolve to a regular file readable by `developer`; and the
default `agent` set in `settings.json` must be named (`name:` frontmatter) by one of those agents, so
an upstream rename in the unpinned `credfeto-ai-skills` fails the build instead of silently dropping
the default agent.

### Stage 2 — acceptance test suite

After the sanity check passes, the upstream acceptance test suite (`/opt/pre-commit/acceptance-test`) is run as the `developer` user against the installed hook chain:

1. `/opt/pre-commit` is copied to `/tmp/pre-commit-test` and its ownership is set to developer:developer.
2. `/tmp/pre-commit-test/.env` is removed so the orchestrator's network-dependent freshness check is skipped (non-freshness tests still run).
3. `su developer -c /tmp/pre-commit-test/acceptance-test` is executed.
4. The temporary copy is removed, and the upstream `install`, `install-deps-arch` and `install-deps-debian` scripts and their `lib/` helpers are pruned from `/opt/pre-commit`. The suite's own tests need them, but the image does not use them (PATH is wired directly via `ENV`).

The build fails if the acceptance suite exits non-zero.

---

## Suggestions for further lock-down

- **`chattr +i` on NuGet.Config** — if the host kernel supports it and the build tooling does not object, setting the immutable attribute (`chattr +i /home/developer/.nuget/NuGet/NuGet.Config`) prevents even root from removing or overwriting the file at runtime without explicitly clearing the attribute first. This is an additional defence in depth on top of the 0444 mode.

- **Separate `$HOME` for agent vs. tooling** — the agent process and the .NET tools currently share `/home/developer`. Giving the agent process a distinct home directory (e.g. `/home/agent`) while keeping .NET tools under `/home/developer` would further reduce the blast radius if the agent gains unexpected write access in its own home.

- **Read-only filesystem mounts for `/opt/*` at runtime** — directories such as `/opt/pre-commit`, `/opt/git-global-hooks`, `/opt/cc-devops-skills`, and `/opt/dotnet-claude-kit` could be bind-mounted read-only at container startup (`--mount type=bind,source=...,target=...,readonly` or a `tmpfs` overlay). This prevents runtime tampering even if a process escalates to root inside the container.
