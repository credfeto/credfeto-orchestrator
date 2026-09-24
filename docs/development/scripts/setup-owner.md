# setup-owner

Provisions a dedicated Linux system user for one orchestrator owner, copies in the credentials the admin has staged, and installs the timer.

Back to the [development guide](../README.md).

## Purpose

Each GitHub owner the orchestrator works for gets its own Linux account, checkout and timer (see `docs/deployment-and-setup.md`). `setup-owner` builds that account on the current machine. A human administrator runs it as themselves, not as root and not inside a Claude Code session; it uses `sudo` internally. It is idempotent, but different steps skip or refresh existing state differently (see Gotchas).

## Running it

```bash
setup-owner --owner <name>
```

- `--owner` is required and must match `^[a-z][a-z0-9_-]*$`. Anything else dies with `Unknown argument`, `--owner requires a value` or a usage message.
- The script dies if `id -u` is 0 or if `is_ai_agent` is true (`CLAUDECODE=1`).

Environment variables:

- `HOME` (as `SOURCE_HOME`) and `XDG_CONFIG_HOME` (as `SOURCE_CONFIG`, default `${HOME}/.config`) locate the admin's staged material.
- `SUDOERS_DIR` (default `/etc/sudoers.d`) is where `revoke_sudoers` looks; it is overridable mainly so tests can redirect it.
- `REPO_URL` is a fixed assignment (`git@github.com:credfeto/credfeto-orchestrator.git`), not an override.

Inputs, all from the admin's account. `validate_source_config` requires three before anything is changed: `${SOURCE_CONFIG}/gh/hosts.yml`, `${SOURCE_CONFIG}/orchestrator/.env`, and `${SOURCE_CONFIG}/orchestrator/tokens/<owner>` with mode 600 or 400. It checks only that `.env` exists, not what it contains. Optional inputs are `~/.ssh`, `~/.database`, and the GPG secret key named by `GIT_SIGNING_KEY` in `.env` (exported with `gpg`, plus `trustdb.gpg` and `sshcontrol` from `~/.gnupg` when present). `GIT_USER_NAME`, `GIT_USER_EMAIL` and `GIT_SIGNING_KEY` are read from `.env` with `grep`, not by sourcing it.

Outputs, all under the new owner's home (from `getent passwd`): `.ssh`, `.gnupg`, `.gitconfig`, `.database`, `.config/gh`, `.config/orchestrator/.env`, `.config/orchestrator/tokens/<owner>`, `.config/containers/storage.conf`, `.config/containers/containers.conf` and the checkout `credfeto-orchestrator`. It also creates the user, enables linger, and removes `${SUDOERS_DIR}/<owner>` if present.

Exit codes: 0 on success, 1 from any `die`. Pre-flight problems are all printed first and then `Pre-flight checks failed`.

## How it works

The script sources `lib/core` (via `SETUP_OWNER_DIR` from `BASH_SOURCE`, with a fatal fallback) for `die`, `success`, `info`, `warn` and `is_ai_agent`, then defines its own `check_required_tools`, which replaces the `lib/core` one and requires `id sudo useradd getent git loginctl`. `main` then runs:

1. `check_required_tools`, `validate_source_config`.
2. `ensure_user_exists`: `useradd -m -s /bin/bash` then `passwd -l`, skipped if `id` finds the user.
3. `enable_linger`: `loginctl enable-linger`.
4. `revoke_sudoers`: remove any sudoers file for the owner.
5. `copy_dotfiles`: `copy_dotdir` for `.ssh`, `sync_gnupg`, `configure_git`, `copy_dotfile` for `.database`.
6. `copy_config_files`: `copy_config_dir` for `gh`, `copy_config_file` for `.env` and the owner's token.
7. `configure_podman_storage` (overlay with `fuse-overlayfs` if available, else `vfs`; graphroot under `~/work` when it is btrfs per `findmnt`) and `configure_podman_engine` (`cgroup_manager = "cgroupfs"`).
8. `clone_or_pull_repo`: clone, or reassert ownership when drift is found and `git pull --ff-only`, as the owner via `sudo -u`.
9. `run_install_timer`: runs the clone's `install-timer --owner <name>` as the owner.

Other tools used but not checked: `passwd`, `gpg`, `pkill`, `find`, `stat`, `tee`, `cp`, `rm`, `chown`, `chmod`, `mktemp`, `mv`, `mkdir`, `touch`, `dirname`, `basename`, `grep`, `cut`, `tr`, `sed`, and the optional `findmnt` and `fuse-overlayfs`; `ssh` is implied by the SSH clone URL.

## Tests

`test/setup-owner.bats` loads `test_helper`, calls `setup_isolated_env`, points `SUDOERS_DIR` at a temp directory, and calls `source_setup_owner`. Nothing runs as a subprocess: `id` and `sudo` are replaced by bash functions exported with `export -f`, and `getent` is overridden per test the same way. `useradd`, `git` and `loginctl` get `make_stub 'exit 0'` stubs, and `getent` gets `make_stub 'exit 1'` (a failed lookup) unless a test overrides it.

The `sudo` function appends its arguments to `${TEST_TMP}/sudo.log` and only performs the subcommands a test needs (`rm`, `mkdir`, `tee`, `cp`, `mv`, `find`, `-u`); `chown` and `chmod` are no-ops. Tests assert on the log lines, on files written under `TEST_TMP`, and on their order (for example the ownership `chown` before the pull). Tests that need other `sudo` behaviour redefine the function inline, and several redefine `command` to hide `fuse-overlayfs`, or use a `make_stub` for `findmnt`. `stub_sudo_for_copy_dotdir` hard-codes `/bin/rm`, `/bin/cp`, `/bin/mv` and `/usr/bin/find`, so it assumes those paths exist on the host.

Covered: `check_required_tools`, `enable_linger`, `revoke_sudoers`, `configure_podman_storage`, `configure_git`, `copy_dotdir` (refresh and known_hosts backup and failure paths), `clone_or_pull_repo` (#1300 ownership drift) and `configure_podman_engine`. Not covered by any test: `main` (including the root and AI-session refusals), `validate_source_config`, `ensure_user_exists`, `copy_dotfiles`, `copy_config_files`, `copy_dotfile`, `copy_config_file`, `copy_config_dir`, `sync_gnupg`, the clone branch and the "exists but is not a git repository" die of `clone_or_pull_repo`, and `run_install_timer`. `get_owner_home` is used only indirectly through the per-test `getent` overrides; its empty-result path is not tested.

Run just this file with `bats test/setup-owner.bats`.

## Changing it safely

- Run `shellcheck setup-owner` and keep it clean.
- Run `bats test/setup-owner.bats`, and `shellcheck test/setup-owner.bats` if you touched the test file.
- Mutation-check each new test: break the code it covers and confirm the test fails. Because `sudo` is a logging fake, check the assertion really depends on the argument you changed.
- Update `README.md`, `docs/deployment-and-setup.md` and `ai/local/debugging.instructions.md` (which cites this script's layout) if behaviour they describe changes.
- Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- The pre-commit hooks run the whole bats suite, so commits and pushes take minutes; run them in the background.

## Gotchas

- There is no `set -e`, `set -u` or `pipefail`; each command needs its own `|| die`. In `sync_gnupg` the pipeline `gpg --export-secret-keys | sudo -u <owner> gpg --import || die` reports only the last command's status, so a failed export is noticed only if the import also fails. What `gpg --import` does with empty input was not checked.
- Reading `.env` with `grep '^GIT_USER_NAME='` means an `export GIT_USER_NAME=...` line or an indented line is silently missed. Quote stripping differs per variable (`sed` for name and email, `tr` for the signing key).
- `configure_git` rewrites the whole `~/.gitconfig` with `tee` on every run, but skips (leaving any existing file) when name or email is empty.
- Refresh semantics differ: `copy_dotdir` (`.ssh`) and `copy_config_dir` (`gh`) delete and recopy; `copy_config_file` always overwrites; `copy_dotfile` (`.database`) skips if the destination exists; `sync_gnupg` wipes `~/.gnupg` and kills the owner's `keyboxd` and `gpg-agent` (only when `GIT_SIGNING_KEY` is set in `.env`; otherwise it returns early and skips the GPG keyring sync). A destination-only `.ssh/known_hosts` is backed up and restored.
- `copy_config_file` runs `chown -R` on the owner's whole `~/.config` each time.
- Order matters: `.ssh` is copied before the SSH clone in `clone_or_pull_repo`, and the clone must exist before `run_install_timer`. On a first run the owner's `known_hosts` comes only from the admin's `~/.ssh/known_hosts` (copied with the directory). The script never adds GitHub's host key or sets `StrictHostKeyChecking`, so the SSH clone works only if the admin's `~/.ssh` already trusts github.com (or its ssh config disables the check).
- `get_owner_home` is `getent passwd | cut`, so the `|| die` after `owner_home=$(get_owner_home ...)` almost never fires (the pipeline status is `cut`'s). The explicit empty-value check on the next line is what actually catches a missing user. In general, a `die` inside a `$(...)` would be swallowed, so callers must not rely on it.
- The `id` function override in the tests is exported, so it also affects any subprocess the test starts.
- GitHub API behaviour (listing lag, `gh project` having no single-item read, `-L` paging) does not affect this script. It makes no GitHub API calls; it only copies `gh`'s config and clones over SSH.
