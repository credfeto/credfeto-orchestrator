# Claude Code hooks and permission files

The agent container's Bash guardrails are a chain of `PreToolUse` hook scripts, four policy data files and the `claude-managed-settings.json` permission list, all in `containers/base/development-full/`.

Back to the [development guide](README.md).

The rules for changing them (the extension process, the widening rules, the deny-flag pairs, the long history of each hook) are in [ai/local/claude-hooks.instructions.md](../../ai/local/claude-hooks.instructions.md). This page is the map; it does not repeat those rules.

## What is where

- `claude-hooks/` holds the executable hooks: `reject-obfuscated-commands`, `enforce-allowed-dirs`, `enforce-git-identity`, `enforce-git-dash-c`, `block-git-worktree`, `block-dotnet-tool-install`, `block-github-mcp-write-tools`, `block-config-skills`, `enforce-ssh-host-and-key`, `enforce-curl-host`, `enforce-background-for-long-running-commands` and `cache-gh-lookups`. It also holds four data files: `command-allowlist`, `command-blocklist`, `env-var-blocklist` and `allowed-dirs`.
- `claude-managed-settings.json` wires the hooks under `hooks.PreToolUse`, holds `permissions.allow` and `permissions.deny` (with `defaultMode` set to `dontAsk`), and sets `allowManagedPermissionRulesOnly`, `allowManagedHooksOnly` and `allowManagedMcpServersOnly`, so no user or project `.claude/settings*.json` can add permissions, hooks or MCP servers. Every hook command is an absolute `/etc/claude-code/hooks/<name>` path, apart from `block-no-verify`. `claude-user-settings.json` holds only preferences (model, theme, environment variables and so on).
- The Dockerfile copies `claude-managed-settings.json` to `/etc/claude-code/managed-settings.json` and the hooks and data files into `/etc/claude-code/hooks/` (hooks `root:root 0755`, data files and settings `root:root 0444`, both directories `root:root 0755`), and `claude-user-settings.json` and `claude-policy-limits.json` to `/home/developer/.claude/settings.json` and `policy-limits.json` (`root:root 0444`). Its sanity block fails the build if any is missing or has the wrong owner or mode, if the managed settings lack those locks or do not disable bypass-permissions mode, if `~/.claude/settings.json` holds permissions, hooks, sandbox or MCP configuration, if a hook command is anything but `block-no-verify` or a path under `/etc/claude-code/hooks/`, or if an `allowed-dirs.local` was baked in. The guarantee is `/etc/claude-code`, root-owned along with every ancestor directory. A root-owned `~/.claude` only stops direct writes: `developer` owns `/home/developer`, so code run by a writer could rename `~/.claude` away and recreate it, adding skills or agents (the managed locks still stop it adding permissions, hooks or MCP servers). That falls under the accepted "code run by a writer" gap.
- `install-claude-hooks` installs the same layout on a host. With `sudo install` it copies every file directly under `claude-hooks/` into `/etc/claude-code/hooks/` (scripts 0755, data files 0444) and `claude-managed-settings.json` to `/etc/claude-code/managed-settings.json`, all `root:root`, so an edit takes effect only once the script is run again; when sudo is missing or declined it prints the commands to run instead. It copies `claude-user-settings.json` to `~/.claude/settings.json` (keeping the old one as `settings.json.bak`), removes any `~/.claude/hooks` symlinks an earlier version left pointing into the checkout, and installs `cfwf`. The symlinks are removed and an existing `settings.json` replaced only once the managed files are installed; without them, the settings are copied only when there is no `settings.json` yet. It refuses to run inside a Claude Code session (`CLAUDECODE=1`) or if `jq`, `shfmt`, `base64`, `realpath`, `git`, `gpg`, `ssh-add`, `sed` or `grep` is missing, because a hook whose tool is missing blocks every command. The baked `allowed-dirs` lists the container mounts, so on a host it warns until an `/etc/claude-code/hooks/allowed-dirs.local` exists: pass a file of host roots as its first argument and it installs that file there, root-owned.
- `block-no-verify` also appears in `hooks.PreToolUse` (for `Bash` only, since `block-github-mcp-write-tools` took over the `mcp__github__.*` matcher). It is an npm tool installed by the `development-node` image (inherited by the images above it), not a file in `claude-hooks/`.

## What a hook sees

A `PreToolUse` hook receives the tool call as JSON on stdin. The Bash hooks read `.tool_input.command` and nothing else about the work (for an `EnterWorktree` call, `block-git-worktree` reads `.tool_input.path` and `.tool_input.name`); only `enforce-background-for-long-running-commands` reads `.tool_input.run_in_background`, and `block-git-worktree` also reads `.tool_name`. `block-github-mcp-write-tools`, registered against the `mcp__github__.*` matcher rather than `Bash`, reads only `.tool_name`, because an MCP tool call has no command string to parse. `block-config-skills`, under the `Skill` matcher, reads `.tool_input.skill`.

The hook sees only the command string the agent typed. It does not see what a script or program does when it runs. `reject-obfuscated-commands` states this as an accepted gap: writing a script file and running it under an allowlisted name cannot be closed by a command-string filter. In practice:

- A multi-step `gh` pattern inside a script (or inside `cfwf`, which is one allowlisted word covered by `Bash(cfwf *)`) is invisible to every hook.
- The same steps typed one at a time are each parsed and checked, so each must satisfy the allowlist, the git rules and the permission patterns on its own. This is why `cfwf` exists: one flat command per recurring multi-step pattern.

The hooks parse the command with `shfmt --tojson` and walk the syntax tree (every call expression at any depth, including inside `$(...)`, loops, pipelines and subshells), so a heredoc body that only mentions `git push` is not treated as a command. `enforce-git-identity` is the exception: it uses a text regex (see below). The `Bash` hooks are listed in `claude-managed-settings.json` in the order of the sections below; the hooks' own comments assume that an earlier one has already run, and this repo does not test how Claude Code schedules them.

## How a denial surfaces

A blocking hook exits 2 and writes its reason to stderr. Nearly all of them use `Blocked (command did not run - fix and retry, do not wait for it): <reason>`; `enforce-git-identity` prints plain `Blocked: <reason>`. Claude Code shows this to the agent as a hook error naming the hook. The wording exists because a denied call never started, so there is nothing to wait for. A denial from the permission system (`dontAsk` with no matching allow entry) names no hook; the difference is described in [ai/global/claude-hooks.instructions.md](../../ai/global/claude-hooks.instructions.md).

A hook that exits 0 with no output allows the call. A hook can also exit 0 and print JSON with `hookSpecificOutput.permissionDecision: "allow"` and an `updatedInput`, which rewrites the command. `reject-obfuscated-commands`, `enforce-git-dash-c` and `cache-gh-lookups` do this. The rewrite is merged into the original `tool_input`, so fields such as `run_in_background` and `timeout` survive (#1367).

Every hook in the `Bash` chain except `enforce-git-identity` and `cache-gh-lookups` blocks when `shfmt` is missing or the command does not parse as shell; `block-github-mcp-write-tools`, `block-config-skills` and the `Edit|Write|NotebookEdit` registration of `enforce-allowed-dirs` parse no shell. Only `enforce-allowed-dirs`, `block-git-worktree`, `block-github-mcp-write-tools`, `block-config-skills`, `enforce-ssh-host-and-key` and `enforce-curl-host` check for `jq` themselves; the others treat a missing `jq` as an empty command and allow it, so the chain relies on `enforce-allowed-dirs` (second) blocking. `cache-gh-lookups` never blocks. This was read from the code, not probed.

## The hooks

In chain order. Behaviour below was checked against the scripts (and their tests, except `enforce-git-identity`, which has none).

### reject-obfuscated-commands

It runs first and applies these layers in order:

- Layer 0 swaps a fixed table of harmless Unicode (em and en dash, curly quotes, non-breaking space, arrows, ellipsis) for ASCII, then rejects any remaining byte outside printable ASCII.
- The command must parse as shell.
- Function definitions and `declare`/`export`/`local`/`readonly` are rejected, and so is an assignment to any variable in `env-var-blocklist` (`IFS`, `PATH`, `LD_*`, `GIT_*`, `npm_config_*`, the `*_proxy` names), matched case-insensitively.
- Every command name, at any depth, must be one plain literal word.
- An interpreter given an inline-code flag (`bash -c`, `python3 -c`, `node -e`, `node -p`, also nested as an argument such as `uv run python3 -c`) is rejected. The exact flags `-p`, `--print`, `-i` and `--interactive` count only for `node`/`nodejs`, since for a shell they are just privileged or interactive mode. A short flag glued to its value (`-cX`, `-eX`, `-pX`) and a long flag glued to its value with `=` (`--eval=...`) are rejected for every interpreter. Every argument after the interpreter name is checked, including the script's own arguments, so `python3 script.py -env prod`, `python3 -m pytest -pno:cacheprovider` and `node .github/actions/a/b.js -config x` are rejected too. This is a known limitation: it fails closed, and fixing it needs per-interpreter tracking of where option parsing ends.
- Names in `command-blocklist` are rejected (`eval`, `source`, shells, and wrappers such as `env`, `sudo`, `command`, `timeout`, `xargs`, `time`, and the container runtimes `podman`, `docker` and `nerdctl`).
- Anything not in `command-allowlist` is rejected. Only the first word of each line is the name (the second is the writer/read-only classification `enforce-allowed-dirs` reads). Path-qualified names match by basename. Exactly `set -e` is let through as a special case.

### enforce-allowed-dirs

It is the single write-target policy. It holds every path a command writes, and the path arguments of `cd`, `pushd`, `git -C`, `npm --prefix`, `find` starting points and `rm`, `mv` and `cp` operands, to the roots in `allowed-dirs` (`/workspace/repo`, `/workspace/rules`, `/workspace/tmp`; `allowed-dirs.local` takes precedence when present). It also keeps every write away from Claude Code's own configuration: a `.claude` directory, `.claude/settings*.json*`, everything under `.claude/hooks`, `.claude/agents` and `.claude/skills`, `.claude.json`, `.mcp.json` and `/etc/claude-code`, wherever they sit. The tracked sources under `containers/base/development-full/` have no `.claude/` path segment, so they stay editable.

It is registered twice: second in the `Bash` chain, and under its own `Edit|Write|NotebookEdit` matcher, where it checks only `.tool_input.file_path` or `.tool_input.notebook_path` against the protected paths, with no roots check and no shell parsing. An empty `tool_name` is treated as `Bash` and any other unrecognised one is blocked.

For a command, every call's command must be classified in `command-allowlist` as `writer` or `read-only`, and an unclassified one is blocked (exactly `set -e` counts as read-only). The write targets are the words of the writing redirections (`>`, `>>`, `>|`, `&>`, `&>>`, `<>`, and `>&` to a file) and, for a writer, its arguments: by default every non-option argument, every `--option=value` value and every tail of a short-option word (`-o/etc/x`), since a glued value cannot be told from a flag cluster. `rm`/`mv`/`cp`, `ln`, `git` (only `checkout`, `restore`, `mv`, `rm` and `clone`, or a call with an `--o...` option), `gh` (every call except a command on the hook's read-only table of commands that write no local file, such as `pr create`/`comment`/`edit`/`view`, `issue create`/`comment`, `api` and `run view`, with `pr merge`/`close` only without `-d`; an unknown command, alias, extension or non-literal command word is a writer, `repo clone`/`fork`/`create` also check the directory named after the repository, a gh writer counts as able to create symlinks, and `gh alias set`/`import` block), `dotnet changelog` (its message is text), `mktemp` (also `$TMPDIR` when no template is given) and `sed`/`awk` have their own rules:

- A `sed` or `awk` program is checked as text against the protected names only, and its files are write targets only when editing in place. In that text anything after `claude-code/` matches wherever it sits, not only after `etc/`, because a link to `/etc` reaches `/etc/claude-code` without naming `etc`.
- For `ln -s` the link it creates is a write target, and every target it points to, in every form (`ln -s T L`, several targets into a directory, `-t DIR`, `--symbolic`, a cluster such as `-sf`), is text-checked like a program against the protected names and also blocked anywhere inside a `.claude` tree or the `claude-code` directory, since a later write through the link would reach them. A target must be a literal path: a variable, substitution or other expansion (`ln -s "$HOME/.claude" c`) blocks, an unquoted brace expansion blocks, and every current match of an unquoted glob is checked as a path. A hard `ln` checks every operand, its targets included, as a write target.

A write target must be fully literal (a variable or substitution blocks), must not be a protected path (checked with `realpath -ms` and `realpath -m`, with unquoted globs expanded) and must be under a root; `/dev/null`, `/dev/stdout` and `/dev/stderr` are always allowed.

Every word is checked as bash passes it to the command: quoting removed, and with it each backslash bash removes (every unquoted one, and inside double quotes one before `$`, `` ` ``, `"` or `\`), so `find -\exec` is checked as `-exec`. A single-quoted backslash, which the command does receive, is kept, so `sed 's/\.claude\.json/x/'` stays allowed. Because `awk` decodes the escapes in its string literals and `-v`/`name=value` values, and `sqlite3` those in a double-quoted dot-command argument (`.once "\056claude/..."`), before using the text as a file name, awk program text and every writer argument are also checked with those escapes decoded. A `\u` escape followed by a hex digit blocks outright there, since gawk 5.3+ and `sqlite3` decode it as a code point and gawk reads no fixed number of digits. `sed` text is not decoded, because GNU `sed` reads a `w` file name literally.

A writer can also write into its working directory without naming a path (`curl -O`, `gh release download`), so a writer (`git` and `gh` only when they write) is blocked when it runs anywhere inside a `.claude` tree or `/etc/claude-code`: a `$PWD`, leading `cd` or `git -C` target there, or a `cd` into one anywhere in the same command. A `cd` there to read, with no writer, stays allowed.

Paths are resolved with `realpath -m`, relative ones against the hook's working directory or a single leading `cd`. A `cd` or `pushd` target is checked where bash's logical `cd` lands: `..` removed as text (`realpath -ms`), then resolved (`realpath -m`), so `cd .claude/link/..` is checked as `.claude` wherever `link` points. The landing must be under a root and an existing directory the shell can enter, with every component before a `..` a directory, because otherwise bash falls back to a physical `cd` the hook does not follow. It also denies flags that turn a path into code execution (`find -exec`, `-delete`, `git --exec-path`, `--git-dir`, `--work-tree`, `npm --script-shell`, `rm --no-preserve-root`) and any `git -c` key outside a short inert list. There is no auto-correction. Code run by a writer (which can also replace the root-owned `~/.claude` wholesale, since `developer` owns `/home/developer`), an `awk` or `sed` program that builds a file name at run time, and the git subcommands that write the working tree from commit content (`merge`, `cherry-pick`, `reset --hard`, `stash`, `pull`, `switch`, `checkout <branch>`, `rebase`) are accepted gaps; a writer argument or program that merely mentions a protected path is an accepted false positive, as is text naming anything under a `claude-code` directory (`node_modules/@anthropic-ai/claude-code/cli.js`), an `ln -s` target inside a `.claude` tree, and awk text or a writer argument that only mentions an escaped spelling of a protected name or has a `\u` escape (`awk '{print "\u00e9"}'`). It fails closed when `jq`, `realpath` or `shfmt` is missing, when `command-allowlist` cannot be read, and when no roots are configured for a check that needs one.

### enforce-git-identity

It blocks `git commit`, `fetch`, `pull`, `rebase`, `merge`, `cherry-pick`, `revert` and `am` unless the global git identity is set and is not the banned one, `commit.gpgsign` is true, and a GPG secret key matches `user.email` and `user.signingkey`. It matches with a regex on the command text after stripping heredocs, and `git` must start a line or follow `;`, `&&` or `||`. Because the gate only matches `git` at the start of a line or after `;`, `&&` or `||`, `echo hi | git -C . commit` and `x=$(git -C . commit -m y)` are not gated by this hook; nothing tests this.

### enforce-git-dash-c

It requires every `git` call to use `git -C <dir>` (except `clone` and `config`, which have their own policy) and only allows the subcommands in its `GIT_ALLOWED_SUBCOMMANDS` array (for example `remote` is refused). It blocks `eval`, `source` and `.`, all `git config` writes at any scope, `--no-verify` (and its abbreviations, and `-n` on `commit`) and a `HUSKY=0` override. A bare `git` call is rewritten to `-C "$PWD"` when the command contains no `cd`/`pushd`/`popd` and `$PWD` is inside a writable git checkout; otherwise it is blocked.

### block-git-worktree

It blocks `git worktree add` and, through a second `EnterWorktree` matcher, the native `EnterWorktree` tool (unless it only switches into an existing worktree). An unrecognised `tool_name` is blocked. The other `git worktree` subcommands pass.

### block-dotnet-tool-install

It blocks `dotnet tool install` and `dotnet new tool-manifest` (also behind a wrapper name), because .NET tools are pinned in the image. `claude-managed-settings.json` denies the same two patterns as well.

### block-github-mcp-write-tools

Registered against the `mcp__github__.*` matcher, not the `Bash` chain above. It blocks the five GitHub MCP tools that write through the API directly (`create_or_update_file`, `delete_file`, `push_files`, `merge_pull_request`, `update_pull_request_branch`), bypassing local git hooks, and fails closed on a missing/empty `tool_name`. Other `mcp__github__*` tools (read-only ones) pass.

### block-config-skills

Registered against the `Skill` matcher, not the `Bash` chain above. It blocks the skills that edit Claude Code's settings, permissions, hooks, keybindings or skill definitions (`update-config`, `fewer-permission-prompts`, `keybindings-help`, `init`, `plugin-authoring`, `skill-creator`), matching both the full `.tool_input.skill` name and the part after its last `:`, so a plugin or directory prefix does not get past. The `Skill(...)` denies in `permissions.deny` cover the same skills; this hook is a second layer that does not depend on how Claude Code matches those rules. It applies to every caller, including a human typing the slash command, and fails closed on a missing `jq`, an unparseable payload or an empty skill name.

### enforce-ssh-host-and-key

It allows only `ssh user@host command...` with no flags, where the target matches `^[A-Za-z0-9._-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.lan$`, and only when `SSH_AUTH_SOCK` is set and `ssh-add -l` succeeds. It also inspects the one word after the target, because ssh would parse a flag there.

### enforce-curl-host

It allows curl only with the flags in `ALLOWED_NOARG_FLAGS` and `ALLOWED_ARG_FLAGS` and one literal URL whose host is not `api.github.com`, `github.com`, `registry.npmjs.org`, `raw.githubusercontent.com` or `api.nuget.org`. Any flag not in those arrays (for example `-X`) is blocked, and so are a non-literal word and an unquoted brace, tilde, glob or backslash character. The header records that `-L` redirects to a denied host are an accepted gap.

### enforce-background-for-long-running-commands

It blocks `git commit`, `pre-commit`, `pre-commit-check`, `buildtest`, `dotnet build`, `dotnet test`, `npm test` and `bun test` unless `run_in_background` is exactly `true`, and fails closed on an unresolved (non-literal) subcommand in the same position, since it could resolve to one of those at runtime. `git push` is not in its list.

### cache-gh-lookups

It rewrites exactly `gh api user --jq '.login'` (one bare call, no pipe, redirect, assignment prefix or extra argument) into a read of `${XDG_CACHE_HOME:-${HOME}/.cache}/orchestrator/global/user.json`, refilled from the API only if the file is empty. Anything else passes through untouched.

## The allowlist, the settings and the parity tests

`command-allowlist` decides which command names `reject-obfuscated-commands` accepts; `permissions.allow` in `claude-managed-settings.json` is a separate layer that Claude Code applies on top, so a name needs an entry in both. `command-blocklist` wins over the allowlist (`xargs` is in both and is unusable). `test/command-allowlist-parity.bats` fails when:

- a `command-allowlist` name has no `Bash(<name> ...)` entry in `permissions.allow`, or the reverse. Names on the blocklist and names with a whole-command deny (such as `sqlcmd`) are excluded, and `set` is the one narrow exception (`NARROW_ALLOW_ONLY_NAMES`, with `Bash(set -e)`).
- a bare non-Bash tool such as `Monitor`, `Edit` or `WebFetch` is missing from `permissions.allow`.
- a `command-allowlist` entry is not a name followed by exactly one of `writer` or `read-only`.
- a `Read(**/...)` or `Edit(**/...)` deny is added, or the `~/.database` rules change.

Other tests hold copies together: `test/enforce-curl-host.bats` checks `DENIED_HOSTS` against the `WebFetch(domain:...)` denies, `test/entrypoint-cache-path-parity.bats` checks the cache path in `cache-gh-lookups` against `entrypoint.sh`, and `test/install-claude-hooks.bats` checks the install itself and the managed settings it installs. For the install: every file in `claude-hooks/` (and nothing else, never an `allowed-dirs.local`) is copied as a real file with the right modes, `claude-managed-settings.json` is installed verbatim and read-only as `/etc/claude-code/managed-settings.json`, every root install goes through `sudo` as `root:root` with the commands printed when `sudo` is missing or declined, `claude-user-settings.json` is copied verbatim to `~/.claude/settings.json` with the old one kept as `settings.json.bak`, stale hook symlinks are removed, `cfwf` is installed, and the required-tools list is enforced. For the managed settings: the locks and disabled bypass mode, absolute `/etc/claude-code/hooks` hook paths (apart from `block-no-verify`) with every hook present in `claude-hooks/` and copied by the Dockerfile, no hardcoded home path, `enforce-allowed-dirs` immediately after `reject-obfuscated-commands`, `block-git-worktree`, `block-dotnet-tool-install` and `cache-gh-lookups` wired in, the `EnterWorktree`, `mcp__github__.*` and `Edit`/`Write`/`NotebookEdit` registrations, the `Edit` denies for the repo's own settings files, and the code-execution flag denies. It also checks that the user settings hold preferences only. `WRAPPERS` (seven hooks), `block()` (ten) and `in_list` (`enforce-git-dash-c`, `enforce-allowed-dirs`) are copied into each hook that needs them rather than sourced, so a change must be repeated in each.

## Adding a hook

1. Write `claude-hooks/<name>` (bash, `export LC_ALL=C`). Read stdin with `jq -r '.tool_input.command // .command // ""'`, parse with `shfmt --tojson`, exit 2 with a `block()` message for a denial, and fail closed on a missing tool.
2. Register it in `claude-managed-settings.json` under the `Bash` matcher in `hooks.PreToolUse`, at the position it must run, as the absolute path `/etc/claude-code/hooks/<name>`.
3. Add a `COPY` line for it to `/etc/claude-code/hooks/<name>` in `containers/base/development-full/Dockerfile` and add it to the sanity loop that checks `root:root 755`. `install-claude-hooks` needs no change (it copies every file in the directory), unless the hook calls a new external tool, which goes in `REQUIRED_TOOLS`.
4. Write `test/<name>.bats`: `load test_helper`, set `HOOK` to the script, call `setup_isolated_env`, then use `run_hook "<command>" [run_in_background]` (or `run_hook_in_dir "<command>" <dir>` when the result depends on the working directory) and assert `status` (0 or 2) and a substring of `output`. `hook_payload` builds the JSON. For a rewrite, parse `output` with `jq`. Cover allowed, blocked, quoted or obfuscated spellings and the fail-closed paths.
5. Mutation-check the tests, then update the order list in [ai/local/claude-hooks.instructions.md](../../ai/local/claude-hooks.instructions.md). `enforce-git-identity` currently has no bats file; do not copy that.

## Allowing a new command

Follow the process in [ai/local/claude-hooks.instructions.md](../../ai/local/claude-hooks.instructions.md): by default an agent logs the request instead of editing `command-allowlist`, and a human decides. When you are asked to add one, add the name and its classification to `command-allowlist` (`writer` if it can write a file named by its arguments or runs code that can, `read-only` otherwise; `writer` when in doubt), add the narrowest matching `Bash(<name> ...)` entry to `permissions.allow` (one entry per subcommand for a tool with subcommands, no blanket `Bash(<tool> *)`), run `bats test/command-allowlist-parity.bats` and `bats test/reject-obfuscated-commands.bats`, add a case to the latter showing the command is allowed, and mutation-check it. The container needs a rebuild to pick the files up. A host install needs `install-claude-hooks` to be run again, because it copies the hooks, data files and settings into root-owned locations.

## Gotchas

- Non-ASCII anywhere in the command blocks it, including heredoc bodies and quoted arguments such as a commit message. Only the fixed table (dashes, curly quotes, non-breaking space, arrows, ellipsis) is rewritten. Put real Unicode in a file written with the `Write` tool and pass `--body-file`.
- `command -v` is blocked because `command` is on the blocklist; `which jq` passes (`which` is on `command-allowlist`). `type`, `read`, `exit`, `continue` and `break` are not on the allowlist, so a loop that uses them is blocked even when the loop itself is fine.
- A variable as the command name (`x=git; $x status`) is blocked as "quoted, escaped, or dynamically substituted". Variables and substitutions in argument position are fine for this hook (`ls $(pwd)` passed).
- Compound commands are walked, so every call in a pipeline, `&&`/`||` list, loop, `{ ...; }` group or subshell is checked separately. In `enforce-allowed-dirs`, `cd a || cd b` and any `cd` that is not the first call make later relative paths unresolvable, so use absolute paths.
- Per-command assignments such as `FOO=bar ls` pass, unless `FOO` matches `env-var-blocklist`.
- A write target must be a literal path: `> "$out"` or `tee "$log"` is blocked by `enforce-allowed-dirs` even though `reject-obfuscated-commands` passes it. Write to a literal path under a root instead, and split a command in two when an earlier part creates a symlink (`ln`, `cp`, `mv`, a git checkout) and a later part writes a path that does not exist yet.
- A `sed -i` program or other writer argument that mentions a protected path, such as a substitution that rewrites `~/.claude/hooks/`, is blocked. Make that edit with the Edit tool.
- Passing the hooks does not grant permission. `permissions.allow` still applies, and under `dontAsk` an unlisted command is denied without a hook name.
- Tests that expect a bare `git` to be blocked by `enforce-git-dash-c` must use `run_hook_in_dir` with its default directory. Bats runs from this repository's own checkout, so plain `run_hook` would take the auto-correct path instead.
