# install-claude-hooks

Installs the development-full container's Claude Code settings, hook scripts and the `cfwf` helper onto the host user's own machine.

Back to the [development guide](../README.md).

## Purpose

The agent container bakes in a `claude-settings.json` and a set of `PreToolUse` hooks (under `containers/base/development-full/`). `install-claude-hooks` puts the same guardrails into the invoking host user's `~/.claude`, so they can be exercised outside the container, and installs `cfwf` into a shared bin directory. A human runs it on a developer machine; it refuses to run inside a Claude Code session. `docs/deployment-and-setup.md` and `containers/base/development-full/README.md` describe it, and `ai/local/claude-hooks.instructions.md` covers the hooks themselves.

## Running it

```bash
./install-claude-hooks
```

It takes no arguments (`main "$@"` passes them but `main` ignores them) and has no options.

Environment variables:

- `HOME` must be set; the target is `${HOME}/.claude`.
- `CFWF_BIN_DIR` overrides where `cfwf` is installed (default `/usr/local/bin`). It is read when the script is sourced or started.
- `CLAUDECODE=1` makes `is_ai_agent` true, and the script then dies.

Reads: `containers/base/development-full/claude-settings.json` (`SOURCE_SETTINGS`), every regular file directly under `containers/base/development-full/claude-hooks/` (`SOURCE_HOOKS_DIR`) and `containers/base/development-full/scripts/cfwf` (`SOURCE_CFWF`).

Writes:

- One symlink per hook or data file in `~/.claude/hooks/`, pointing back into the repository.
- `~/.claude/settings.json`, a verbatim copy, plus `~/.claude/settings.json.bak` when a settings file already existed.
- `${CFWF_BIN_DIR}/cfwf`, a copy with mode 0755.

Exit codes: 0 on success (including when `cfwf` could not be installed and the script only prints the command to run); 1 from any `die`.

## How it works

The script does not source `lib/core`. It defines its own `die`, `success`, `info` and `is_ai_agent`, which always print ANSI colour codes and have no TTY check. `main` runs these steps:

1. `is_ai_agent` gate, then existence checks for the three source paths.
2. `check_required_tools` checks every name in the `REQUIRED_TOOLS` array (`jq shfmt base64 realpath git gpg ssh-add sed grep`) and dies naming all missing ones at once, before anything is written.
3. `mkdir -p ~/.claude`, then `install_hook_symlinks` runs `ln -sf` for each file found with `find ... -mindepth 1 -maxdepth 1 -type f`, so new hook files are picked up automatically.
4. `install_settings` copies the template to a `mktemp` file, checks it with `jq empty`, copies any existing `settings.json` to `settings.json.bak`, then moves the temp file into place.
5. `install_cfwf` tries `install -m 0755`; if that fails and `sudo` exists it tries `sudo install -m 0755 -o root -g root`; if that also fails or `sudo` is missing it prints the exact `sudo install ...` command via `info` and carries on.
6. `warn_if_no_allowed_dirs_override` prints a note when `~/.claude/hooks/allowed-dirs.local` does not exist.

The settings file is copied unchanged: its hook commands use the literal `$HOME` token, which the shell that runs the hook expands, so no path rewriting is needed.

External tools: those in `REQUIRED_TOOLS`, plus `install`, `find`, `sort`, `ln`, `cp`, `mv`, `mkdir`, `mktemp`, `basename`, `dirname` and optionally `sudo` (not checked).

## Tests

`test/install-claude-hooks.bats` loads `test_helper`. Its `setup()` calls `setup_isolated_env` (which redirects `HOME`), exports `CFWF_BIN_DIR` to a directory under `TEST_TMP` before calling `source_install_claude_hooks` (so tests never write to the real `/usr/local/bin`), makes `make_stub` no-op stubs for any `REQUIRED_TOOLS` entry the host lacks, and stubs `sudo` with `make_stub` so it logs to `SUDO_LOG` and exits 1. That stub means no test can reach the real `sudo`.

Tests call `main` directly (or `run main` when they check status and output) in the same shell. They therefore override script globals such as `SOURCE_HOOKS_DIR`, `SOURCE_SETTINGS`, `SOURCE_CFWF` and `CFWF_BIN_DIR` by plain assignment. Missing-tool tests use the local `hide_tools` helper, which redefines the `command` builtin as a shell function so `command -v <tool>` fails for chosen names without touching the system. The sudo test replaces the stub with `make_stub sudo '... exit 0'`.

Unusual: the first test calls a `fail` function that nothing in `test/` defines (no bats-support is loaded), so if a symlink were missing the failure would surface as "command not found" rather than the intended message. The tests also read the real repository files, so they pin the shipped settings: which hooks are in the `PreToolUse` chain (`block-git-worktree`, `block-dotnet-tool-install`, `cache-gh-lookups`), the single position of `enforce-allowed-dirs` at index 1, the `$HOME` token, the paired `permissions.deny` entries and the `EnterWorktree` matcher. The relative order of the other hooks is not tested.

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

- There is no `set -e`, `set -u` or `pipefail`; every step relies on an explicit `|| die`. `install_cfwf` is the exception by design: failure only prints guidance and the script still exits 0.
- Hook files are symlinks into this checkout, so moving or deleting the checkout breaks every hook, and a hook that fails closed then blocks every command. That is why the required tools are checked first.
- The script never removes symlinks for hooks that have been deleted from the repository, and `ln -sf` replaces a regular file of the same name.
- `settings.json.bak` has a single fixed name and is overwritten on each run, so a second run replaces the backup of your original settings with the previously installed copy.
- `cfwf` is a copy, not a symlink: re-run the script after changing `scripts/cfwf`.
- `allowed-dirs` (shipped, symlinked) lists container paths. On a host, `enforce-allowed-dirs` blocks directory-taking commands until you hand-write `allowed-dirs.local`; the script only warns and never creates it.
- GitHub API behaviour (listing lag, `gh project` having no single-item read, `-L` paging limits) does not affect this script: it makes no GitHub calls. Those concerns live in `cfwf`, which it merely installs.
