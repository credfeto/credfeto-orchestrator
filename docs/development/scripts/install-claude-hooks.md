# install-claude-hooks

Installs the development-full container's Claude Code settings, hook scripts, managed MCP servers and the `cfwf` helper onto the host.

Back to the [development guide](../README.md).

## Purpose

The agent container bakes in a `claude-managed-settings.json`, a `claude-user-settings.json` and a set of `PreToolUse` hooks (under `containers/base/development-full/`). `install-claude-hooks` puts the same guardrails onto a host, in the same root-owned `/etc/claude-code/` layout the container uses, so they can be exercised outside the container, and installs `cfwf` into a shared bin directory. It also installs `/etc/claude-code/managed-mcp.json`, the container's `cfwf` MCP server merged with the host's own MCP servers from `~/.claude.json`, and the `cfwf-mcp-headers` helper that supplies that server's `Authorization` header. A human runs it on a developer machine; it refuses to run inside a Claude Code session. `docs/deployment-and-setup.md` and `containers/base/development-full/README.md` describe it, and `ai/local/claude-hooks.instructions.md` covers the hooks themselves.

## Running it

```bash
./install-claude-hooks [allowed-dirs-file]
```

The optional argument is a file of allowed directory roots for this host (one per line, the `allowed-dirs` format). It is installed as `/etc/claude-code/hooks/allowed-dirs.local`. Without it, and with no `allowed-dirs.local` already installed, the script warns that `enforce-allowed-dirs` will block every directory-taking command.

Environment variables:

- `HOME` must be set; the user settings go to `${HOME}/.claude/settings.json`, and the host's MCP servers are read from `${HOME}/.claude.json`.
- `CFWF_BIN_DIR` overrides where `cfwf` is installed (default `/usr/local/bin`). It is read when the script is sourced or started.
- `CLAUDE_MANAGED_DIR` overrides `/etc/claude-code`, for tests only: the managed settings name every hook by its absolute `/etc/claude-code/hooks/...` path, so a real install must leave it unset.
- `CLAUDECODE=1` makes `is_ai_agent` true, and the script then dies.

Reads: `containers/base/development-full/claude-managed-settings.json` (`SOURCE_MANAGED_SETTINGS`), `containers/base/development-full/claude-user-settings.json` (`SOURCE_USER_SETTINGS`), every regular file directly under `containers/base/development-full/claude-hooks/` (`SOURCE_HOOKS_DIR`), `containers/base/development-full/scripts/cfwf` (`SOURCE_CFWF`), `containers/base/development-full/claude-managed-mcp.json` (`SOURCE_MANAGED_MCP`), `containers/base/development-full/claude-mcp/cfwf-mcp-headers` (`SOURCE_MCP_HEADERS`) and, when it exists, `~/.claude.json`.

Writes:

- `/etc/claude-code/`, `/etc/claude-code/hooks/` and `/etc/claude-code/mcp/` (root:root 0755), one copy per hook (root:root 0755) or data file (root:root 0444) in the hooks directory, `/etc/claude-code/managed-settings.json` and `/etc/claude-code/managed-mcp.json` (root:root 0444), and `/etc/claude-code/mcp/cfwf-mcp-headers` (root:root 0755), all via `sudo install -o root -g root`.
- `~/.claude/managed-mcp.merged.json`, the merged MCP servers that are installed as `managed-mcp.json`. It is overwritten on each run and kept afterwards, so a printed `sudo install` command can still find it.
- `/etc/claude-code/hooks/allowed-dirs.local` (root:root 0444) when the argument is given.
- `~/.claude/settings.json`, a verbatim copy of the user settings, plus `~/.claude/settings.json.bak` when a settings file already existed.
- `${CFWF_BIN_DIR}/cfwf`, a copy with mode 0755.

Removes: every symlink directly under `~/.claude/hooks/` that resolves into this checkout's `claude-hooks/` (left by earlier versions, which linked the hooks instead of copying them). Other entries there are left alone.

Exit codes: 0 on success (including when the root-owned files or `cfwf` could not be installed and the script only prints the commands to run); 1 from any `die`.

## How it works

The script does not source `lib/core`. It defines its own `die`, `success`, `info` and `is_ai_agent`, which always print ANSI colour codes and have no TTY check. `main` runs these steps:

1. `is_ai_agent` gate, existence checks for the six source paths, and a readability check on the argument when one is given.
2. `check_required_tools` checks every name in the `REQUIRED_TOOLS` array (`jq shfmt base64 realpath git gpg ssh-add sed grep`) and dies naming all missing ones at once, before anything is written. The argument is then made absolute, and the managed settings, user settings and managed MCP servers are each checked with `jq empty`, so an invalid file stops the script before anything is installed or removed.
3. `merge_host_mcp_servers` merges the shipped `cfwf` server with the servers in `~/.claude.json` (the top-level `mcpServers` and every `projects.<path>.mcpServers`) and prints a JSON report. A missing or empty `~/.claude.json` adds nothing; an invalid one is fatal. A host server is left out when:
   - its `url` is `cfwf`'s (a trailing `/` is ignored), because `cfwf` replaces it. The script names it and suggests removing it from `~/.claude.json`.
   - any `headers` or `env` value holds literal text rather than only `${VAR}` references (an optional `Bearer`, `Basic` or `Token` scheme word is allowed), because `managed-mcp.json` is world-readable. The script warns, naming the server, and never prints the value.

   The same definition repeated in several scopes is kept once. Two different servers under one name, including a host server named `cfwf` at another URL, are fatal, before anything is written.
4. `mkdir -p ~/.claude`, then `write_merged_mcp` prints the left-out names, writes `~/.claude/managed-mcp.merged.json`, checks it with `jq empty`, and lists the servers it holds with a reminder that the merge is a snapshot.
5. `install_managed_files` runs `root_install` (`sudo install -o root -g root ...`) for the three directories, each file found with `find ... -mindepth 1 -maxdepth 1 -type f` (mode 0755 when the source is executable, 0444 otherwise, so new hook files are picked up automatically) apart from an `allowed-dirs.local` sitting in the checkout, which the agent could have written and so is never copied, the managed settings, the headers helper, the merged `managed-mcp.json` and the optional `allowed-dirs.local`. Once sudo is missing or one call fails, it is not asked again: the remaining commands are collected and printed together.
6. `install_user_files`: when every managed file was installed, `remove_stale_hook_symlinks` deletes the old symlinks described above and `install_user_settings` copies the user settings to a `mktemp` file, checks it with `jq empty`, copies any existing `settings.json` to `settings.json.bak`, then moves the temp file into place. When the managed install did not complete, an existing `settings.json` and the old symlinks are left as they were (so a declined sudo never leaves the previous guardrails removed with nothing in their place), and only a host with no `settings.json` yet gets the user settings.
7. `install_cfwf` tries `install -m 0755`; if that fails and `sudo` exists it tries `sudo install -m 0755 -o root -g root`; if that also fails or `sudo` is missing it prints the exact `sudo install ...` command via `info` and carries on.
8. `warn_if_no_allowed_dirs_override` prints a note when no argument was given and `/etc/claude-code/hooks/allowed-dirs.local` does not exist.

The managed files are never installed with a plain `install`, even into a writable directory: a copy owned by the user would be writable by an agent running as that user, which is what the root ownership exists to prevent.

External tools: those in `REQUIRED_TOOLS`, plus `install`, `find`, `sort`, `cp`, `mv`, `rm`, `mkdir`, `mktemp`, `basename`, `dirname` and `sudo` (not checked; its absence is handled).

## Tests

`test/install-claude-hooks.bats` loads `test_helper`. Its `setup()` calls `setup_isolated_env` (which redirects `HOME`), exports `CFWF_BIN_DIR` and `CLAUDE_MANAGED_DIR` to directories under `TEST_TMP` before calling `source_install_claude_hooks` (so tests never write to the real `/usr/local/bin` or `/etc`), makes `make_stub` no-op stubs for any `REQUIRED_TOOLS` entry the host lacks, and stubs `sudo` so it logs to `SUDO_LOG` and exits 1. That stub means no test can reach the real `sudo`. `allow_sudo` swaps in a stub that logs the command and then runs it without `-o root -g root`, which only root could apply, so the copies, their modes and the logged root-owned `install` calls can all be asserted.

MCP merge tests write a fixture `~/.claude.json` under the isolated `HOME` with `write_host_claude_json` and read the installed server names back with `installed_mcp_names`. `test/cfwf-mcp-headers.bats` covers the headers helper itself; see the [Claude Code hooks guide](../claude-hooks.md#the-cfwf-mcp-server).

Tests call `main` directly (or `run main` when they check status and output) in the same shell. They therefore override script globals such as `SOURCE_HOOKS_DIR`, `SOURCE_MANAGED_SETTINGS`, `SOURCE_USER_SETTINGS`, `SOURCE_CFWF` and `CFWF_BIN_DIR` by plain assignment. Missing-tool tests use the local `hide_tools` helper, which redefines the `command` builtin as a shell function so `command -v <tool>` fails for chosen names without touching the system.

The tests also read the real repository files, so they pin the shipped settings: the managed locks and `disableBypassPermissionsMode`, that every hook command is an `/etc/claude-code/hooks/` path whose script exists and is copied there by the Dockerfile, the first two hooks of the `Bash` chain (`reject-obfuscated-commands`, then `enforce-allowed-dirs`), which other hooks are in it (`block-git-worktree`, `block-dotnet-tool-install`, `cache-gh-lookups`), the `EnterWorktree`, `mcp__github__.*` and `Edit|Write|NotebookEdit` matchers, the relative `Edit` denies, the paired `permissions.deny` entries, that the user settings hold preference keys only, that the shipped `managed-mcp.json` holds only `cfwf` at its `https://` URL with its header from `/etc/claude-code/mcp/cfwf-mcp-headers` and no literal `Authorization` or `${VAR}`, that `mcp__cfwf__*` is allowed, and that the Dockerfile copies both MCP files. The relative order of the remaining hooks is not tested.

Run just this file with `bats test/install-claude-hooks.bats`.

## Changing it safely

- Run `shellcheck install-claude-hooks` and keep it clean. Note that the shellcheck command listed in `ai/local/shell-testing.instructions.md` omits this script; include it anyway.
- Run `bats test/install-claude-hooks.bats`.
- Mutation-check each new test: break the code it covers and confirm the test fails.
- If you add a tool the hooks call, add it to `REQUIRED_TOOLS`; the test "the required tools cover everything the hooks call" holds a fixed list.
- Update `README.md`, `docs/deployment-and-setup.md`, `containers/base/development-full/README.md` and `ai/local/claude-hooks.instructions.md` if the behaviour they describe changes.
- Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- The pre-commit hooks run the whole bats suite, so commits and pushes take minutes; run them in the background.

## Gotchas

- There is no `set -e`, `set -u` or `pipefail`; every step relies on an explicit `|| die`. `install_managed_files` and `install_cfwf` are the exceptions by design: a failed root install only prints guidance and the script still exits 0, but until those commands are run no guardrails are active on the host.
- Every file is a copy, so an edit to a hook, a data file or either settings file takes effect only once the script is run again.
- `managed-mcp.json` takes exclusive control of MCP servers. Claude Code then loads only the servers in it, so a server added to `~/.claude.json` afterwards is ignored until the script is run again. `claude --mcp-config` exits at startup while it is present, and claude.ai connectors are hidden unless the managed settings set `allowAllClaudeAiMcps`.
- Project-scoped host servers become global once merged, because `managed-mcp.json` has no per-project scope.
- The script never removes hooks from `/etc/claude-code/hooks/` that have been deleted from the repository.
- `settings.json.bak` has a single fixed name and is overwritten on each run, so a second run replaces the backup of your original settings with the previously installed copy.
- `allowed-dirs` (shipped) lists container paths. On a host, `enforce-allowed-dirs` blocks directory-taking commands until an `allowed-dirs.local` is installed; the script only installs one from the file you name and never writes one of its own. An `allowed-dirs.local` left in `~/.claude/hooks/` by an earlier version is no longer read: pass it as the argument.
- GitHub API behaviour (listing lag, `gh project` having no single-item read, `-L` paging limits) does not affect this script: it makes no GitHub calls. Those concerns live in `cfwf`, which it merely installs.
