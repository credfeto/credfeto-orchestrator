# Claude Code hooks and permission files

The agent container's Bash guardrails are a chain of `PreToolUse` hook scripts, four policy data files and a `claude-settings.json` permission list, all in `containers/base/development-full/`.

Back to the [development guide](README.md).

The rules for changing them (the extension process, the widening rules, the deny-flag pairs, the long history of each hook) are in [ai/local/claude-hooks.instructions.md](../../ai/local/claude-hooks.instructions.md). This page is the map; it does not repeat those rules.

## What is where

- `claude-hooks/` holds the executable hooks: `reject-obfuscated-commands`, `enforce-allowed-dirs`, `enforce-git-identity`, `enforce-git-dash-c`, `block-git-worktree`, `block-dotnet-tool-install`, `enforce-ssh-host-and-key`, `enforce-curl-host`, `enforce-background-for-long-running-commands` and `cache-gh-lookups`. It also holds four data files: `command-allowlist`, `command-blocklist`, `env-var-blocklist` and `allowed-dirs`.
- `claude-settings.json` wires the hooks under `hooks.PreToolUse` and holds `permissions.allow` and `permissions.deny` (with `defaultMode` set to `dontAsk`).
- The Dockerfile copies each file into `/home/developer/.claude/`: hooks as `root:root 0755`, data files and settings as `root:root 0444`, and its sanity block fails the build if any is missing, if the hook commands contain a hard-coded `/home/developer`, or if an `allowed-dirs.local` was baked in.
- `install-claude-hooks` installs the same set on a host. It symlinks every file directly under `claude-hooks/` into `~/.claude/hooks/` (so an edit takes effect immediately), copies `claude-settings.json` verbatim to `~/.claude/settings.json` (keeping the old one as `settings.json.bak`), and installs `cfwf`. It refuses to run inside a Claude Code session (`CLAUDECODE=1`) or if `jq`, `shfmt`, `base64`, `realpath`, `git`, `gpg`, `ssh-add`, `sed` or `grep` is missing, because a hook whose tool is missing blocks every command. The baked `allowed-dirs` lists the container mounts, so on a host it warns until you write your own `~/.claude/hooks/allowed-dirs.local`.
- `block-no-verify` also appears in `hooks.PreToolUse` (for `Bash` and for `mcp__github__.*`). It is an npm tool installed by the `development-node` and `development-python` images, not a file in `claude-hooks/`.

## What a hook sees

A `PreToolUse` hook receives the tool call as JSON on stdin. The Bash hooks read `.tool_input.command` and nothing else about the work; only `enforce-background-for-long-running-commands` reads `.tool_input.run_in_background`, and `block-git-worktree` also reads `.tool_name`.

The hook sees only the command string the agent typed. It does not see what a script or program does when it runs. `reject-obfuscated-commands` states this as an accepted gap: writing a script file and running it under an allowlisted name cannot be closed by a command-string filter. In practice:

- A multi-step `gh` pattern inside a script (or inside `cfwf`, which is one allowlisted word covered by `Bash(cfwf *)`) is invisible to every hook.
- The same steps typed one at a time are each parsed and checked, so each must satisfy the allowlist, the git rules and the permission patterns on its own. This is why `cfwf` exists: one flat command per recurring multi-step pattern.

The hooks parse the command with `shfmt --tojson` and walk the syntax tree (every call expression at any depth, including inside `$(...)`, loops, pipelines and subshells), so a heredoc body that only mentions `git push` is not treated as a command. `enforce-git-identity` is the exception: it uses a text regex (see below). The hooks are listed in `claude-settings.json` in the order above; the hooks' own comments assume that an earlier one has already run, and this repo does not test how Claude Code schedules them.

## How a denial surfaces

A blocking hook exits 2 and writes its reason to stderr. Nearly all of them use `Blocked (command did not run - fix and retry, do not wait for it): <reason>`; `enforce-git-identity` prints plain `Blocked: <reason>`. Claude Code shows this to the agent as a hook error naming the hook. The wording exists because a denied call never started, so there is nothing to wait for. A denial from the permission system (`dontAsk` with no matching allow entry) names no hook; the difference is described in [ai/global/claude-hooks.instructions.md](../../ai/global/claude-hooks.instructions.md).

A hook that exits 0 with no output allows the call. A hook can also exit 0 and print JSON with `hookSpecificOutput.permissionDecision: "allow"` and an `updatedInput`, which rewrites the command. `reject-obfuscated-commands`, `enforce-git-dash-c` and `cache-gh-lookups` do this. The rewrite is merged into the original `tool_input`, so fields such as `run_in_background` and `timeout` survive (#1367).

Most hooks fail closed: a missing `jq` or `shfmt`, or a command that does not parse as shell, is a block. `cache-gh-lookups` is the exception and never blocks.

## The hooks

In chain order. Behaviour below was checked against the scripts and their tests.

### reject-obfuscated-commands

It runs first and applies these layers in order:

- Layer 0 swaps a fixed table of harmless Unicode (em and en dash, curly quotes, non-breaking space, arrows, ellipsis) for ASCII, then rejects any remaining byte outside printable ASCII.
- The command must parse as shell.
- Function definitions and `declare`/`export`/`local`/`readonly` are rejected, and so is an assignment to any variable in `env-var-blocklist` (`IFS`, `PATH`, `LD_*`, `GIT_*`, `npm_config_*`, the `*_proxy` names), matched case-insensitively.
- Every command name, at any depth, must be one plain literal word.
- An interpreter given an inline-code flag (`bash -c`, `python3 -c`, `node -e`, also nested as an argument such as `uv run python3 -c`) is rejected.
- Names in `command-blocklist` are rejected (`eval`, `source`, shells, and wrappers such as `env`, `sudo`, `command`, `timeout`, `xargs`, `time`).
- Anything not in `command-allowlist` is rejected. Path-qualified names match by basename. Exactly `set -e` is let through as a special case.

### enforce-allowed-dirs

It restricts the path arguments of `cd`, `pushd`, `git -C`, `npm --prefix`, `find` starting points and `rm`, `mv` and `cp` operands to the roots in `allowed-dirs` (`/workspace/repo`, `/workspace/rules`, `/workspace/tmp`; `allowed-dirs.local` takes precedence when present). Paths are resolved with `realpath -m`. It also denies flags that turn a path into code execution (`find -exec`, `-delete`, `git --exec-path`, `--git-dir`, `--work-tree`, `npm --script-shell`, `rm --no-preserve-root`) and any `git -c` key outside a short inert list. There is no auto-correction.

### enforce-git-identity

It blocks `git commit`, `fetch`, `pull`, `rebase`, `merge`, `cherry-pick`, `revert` and `am` unless the global git identity is set and is not the banned one, `commit.gpgsign` is true, and a GPG secret key matches `user.email` and `user.signingkey`. It matches with a regex on the command text after stripping heredocs, and `git` must start a line or follow `;`, `&&` or `||`. A probe run with an empty global config blocked `git -C . commit` and `cd /x && git -C . fetch` but let `echo hi | git -C . commit` and `x=$(git -C . commit -m y)` through, so pipes and substitutions are not covered by this hook.

### enforce-git-dash-c

It requires every `git` call to use `git -C <dir>` and only allows the subcommands in its `GIT_ALLOWED_SUBCOMMANDS` array (for example `remote` is refused). It blocks `eval`, `source` and `.`, all `git config` writes at any scope, `--no-verify` (and its abbreviations, and `-n` on `commit`) and a `HUSKY=0` override. A bare `git` call is rewritten to `-C "$PWD"` when the command contains no `cd`/`pushd`/`popd` and `$PWD` is inside a writable git checkout; otherwise it is blocked.

### block-git-worktree

It blocks `git worktree add` and, through a second `EnterWorktree` matcher, the native `EnterWorktree` tool (unless it only switches into an existing worktree). An unrecognised `tool_name` is blocked. The other `git worktree` subcommands pass.

### block-dotnet-tool-install

It blocks `dotnet tool install` and `dotnet new tool-manifest` (also behind a wrapper name), because .NET tools are pinned in the image. `claude-settings.json` denies the same two patterns as well.

### enforce-ssh-host-and-key

It allows only `ssh user@host command...` with no flags, where the target matches `^[A-Za-z0-9._-]+@...\.lan$`, and only when `SSH_AUTH_SOCK` is set and `ssh-add -l` succeeds. It also inspects the one word after the target, because ssh would parse a flag there.

### enforce-curl-host

It allows curl only with the flags in `ALLOWED_NOARG_FLAGS` and `ALLOWED_ARG_FLAGS` and one literal URL whose host is not `api.github.com`, `github.com`, `registry.npmjs.org`, `raw.githubusercontent.com` or `api.nuget.org`. Any other flag (a probe with `-X` was blocked), a non-literal word, or an unquoted brace, tilde, glob or backslash character is blocked. The header records that `-L` redirects to a denied host are an accepted gap.

### enforce-background-for-long-running-commands

It blocks `git commit`, `pre-commit`, `pre-commit-check`, `dotnet build`, `dotnet test`, `npm test` and `bun test` unless `run_in_background` is exactly `true`. `git push` is not in its list.

### cache-gh-lookups

It rewrites exactly `gh api user --jq '.login'` (one bare call, no pipe, redirect, assignment prefix or extra argument) into a read of `${XDG_CACHE_HOME:-${HOME}/.cache}/orchestrator/global/user.json`, refilled from the API only if the file is empty. Anything else passes through untouched.

## The allowlist, the settings and the parity tests

`command-allowlist` decides which command names `reject-obfuscated-commands` accepts; `permissions.allow` in `claude-settings.json` is a separate layer that Claude Code applies on top, so a name needs an entry in both. `command-blocklist` wins over the allowlist (`xargs` is in both and is unusable). `test/command-allowlist-parity.bats` fails when:

- a `command-allowlist` name has no `Bash(<name> ...)` entry in `permissions.allow`, or the reverse. Names on the blocklist and names with a whole-command deny (such as `sqlcmd`) are excluded, and `set` is the one narrow exception (`NARROW_ALLOW_ONLY_NAMES`, with `Bash(set -e)`).
- a bare non-Bash tool such as `Monitor`, `Edit` or `WebFetch` is missing from `permissions.allow`.
- a `Read(**/...)` or `Edit(**/...)` deny is added, or the `~/.database` rules change.

Other tests hold copies together: `test/enforce-curl-host.bats` checks `DENIED_HOSTS` against the `WebFetch(domain:...)` denies, `test/entrypoint-cache-path-parity.bats` checks the cache path in `cache-gh-lookups` against `entrypoint.sh`, and `test/install-claude-hooks.bats` checks the chain order, the `EnterWorktree` matcher, the verbatim settings copy and the required-tools list. The shared hook list `WRAPPERS`, `block()` and `in_list` are copied into each hook rather than sourced, so a change must be repeated in each.

## Adding a hook

1. Write `claude-hooks/<name>` (bash, `export LC_ALL=C`). Read stdin with `jq -r '.tool_input.command // .command // ""'`, parse with `shfmt --tojson`, exit 2 with a `block()` message for a denial, and fail closed on a missing tool.
2. Register it in `claude-settings.json` under the `Bash` matcher in `hooks.PreToolUse`, at the position it must run.
3. Add a `COPY` line for it in `containers/base/development-full/Dockerfile` and add it to the sanity loop that checks `root:root 755`. `install-claude-hooks` needs no change (it symlinks whatever is in the directory), unless the hook calls a new external tool, which goes in `REQUIRED_TOOLS`.
4. Write `test/<name>.bats`: `load test_helper`, set `HOOK` to the script, call `setup_isolated_env`, then use `run_hook "<command>" [run_in_background]` (or `run_hook_in_dir "<command>" <dir>` when the result depends on the working directory) and assert `status` (0 or 2) and a substring of `output`. `hook_payload` builds the JSON. For a rewrite, parse `output` with `jq`. Cover allowed, blocked, quoted or obfuscated spellings and the fail-closed paths.
5. Mutation-check the tests, then update the order list in [ai/local/claude-hooks.instructions.md](../../ai/local/claude-hooks.instructions.md). `enforce-git-identity` currently has no bats file; do not copy that.

## Allowing a new command

Follow the process in [ai/local/claude-hooks.instructions.md](../../ai/local/claude-hooks.instructions.md): by default an agent logs the request instead of editing `command-allowlist`, and a human decides. When you are asked to add one, add the name to `command-allowlist`, add the narrowest matching `Bash(<name> ...)` entry to `permissions.allow` (one entry per subcommand for a tool with subcommands, no blanket `Bash(<tool> *)`), run `bats test/command-allowlist-parity.bats` and `bats test/reject-obfuscated-commands.bats`, add a case to the latter showing the command is allowed, and mutation-check it. The container needs a rebuild to pick the files up. A host install picks up a changed hook or data file through the symlinks, but a `claude-settings.json` change needs `install-claude-hooks` to be run again because that file is copied.

## Gotchas

- Non-ASCII anywhere in the command blocks it, including heredoc bodies and quoted arguments such as a commit message. Only the fixed table (dashes, curly quotes, non-breaking space, arrows, ellipsis) is rewritten. Put real Unicode in a file written with the `Write` tool and pass `--body-file`.
- `command -v` is blocked because `command` is on the blocklist; `which jq` passes (probed). `type`, `read`, `exit`, `continue` and `break` are not on the allowlist, so a loop that uses them is blocked even when the loop itself is fine.
- A variable as the command name (`x=git; $x status`) is blocked as "quoted, escaped, or dynamically substituted". Variables and substitutions in argument position are fine for this hook (`ls $(pwd)` passed).
- Compound commands are walked, so every call in a pipeline, `&&`/`||` list, loop, `{ ...; }` group or subshell is checked separately. In `enforce-allowed-dirs`, `cd a || cd b` and any `cd` that is not the first call make later relative paths unresolvable, so use absolute paths.
- Per-command assignments such as `FOO=bar git push` pass, unless `FOO` matches `env-var-blocklist`.
- Passing the hooks does not grant permission. `permissions.allow` still applies, and under `dontAsk` an unlisted command is denied without a hook name.
- Tests that expect a bare `git` to be blocked by `enforce-git-dash-c` must use `run_hook_in_dir` with its default directory. Bats runs from this repository's own checkout, so plain `run_hook` would take the auto-correct path instead.
