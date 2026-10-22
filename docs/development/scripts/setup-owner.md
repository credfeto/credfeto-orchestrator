# setup-owner

Provisions a dedicated Linux system user for one orchestrator owner, copies in the credentials the admin has staged, and installs that owner's systemd units and polkit rule.

Back to the [development guide](../README.md).

## Purpose

Each GitHub owner the orchestrator works for gets its own Linux account, checkout and timer (see `docs/deployment-and-setup.md`). `setup-owner` builds that account on the current machine. A human administrator runs it as root, normally through `sudo` from their own account, and never inside a Claude Code session. The script itself never calls `sudo`: it already has the rights it needs, and runs the steps that must happen as the owner through `runuser`. It is idempotent, but different steps skip or refresh existing state differently (see Gotchas). [teardown-owner](teardown-owner.md) reverses the systemd and polkit part.

## Running it

```bash
sudo ./setup-owner --owner <name>
```

- `--owner` is required and must match `^[a-z][a-z0-9_-]*$`. Anything else dies with `Unknown argument`, `--owner requires a value`, `--owner value contains invalid characters` or a usage message.
- The script dies unless `id -u` is 0 (`must be run as root`), and if `is_ai_agent` is true (`CLAUDECODE=1`).

Environment variables:

- `SUDO_USER` decides where the admin's staged material is read from. When it is set and is not `root`, `SOURCE_HOME` is that user's home (from `get_owner_home`) and `SOURCE_CONFIG` is `${SOURCE_HOME}/.config`, because root's own `HOME` holds no credentials. Otherwise (a real root login) `SOURCE_HOME` is `HOME` and `SOURCE_CONFIG` is `XDG_CONFIG_HOME`, default `${HOME}/.config`.
- `SUDOERS_DIR` (default `/etc/sudoers.d`) is where `revoke_sudoers` looks.
- `UNIT_DIR` (default `/etc/systemd/system`, from `lib/systemd-units`) is where the unit files are written.
- `POLKIT_RULES_DIR` (default `/etc/polkit-1/rules.d`) is where the polkit rule is written.
- The last three are overridable mainly so tests can redirect the writes. `REPO_URL` is a fixed assignment (`git@github.com:credfeto/credfeto-orchestrator.git`), not an override.

Inputs, all from the admin's account. `validate_source_config` requires three before anything is changed: `${SOURCE_CONFIG}/gh/hosts.yml`, `${SOURCE_CONFIG}/orchestrator/.env`, and `${SOURCE_CONFIG}/orchestrator/tokens/<owner>` with mode 600 or 400. It checks only that `.env` exists, not what it contains. Optional inputs are `~/.ssh`, `~/.database`, and the GPG secret key named by `GIT_SIGNING_KEY` in `.env` (exported from the admin's keyring, plus `trustdb.gpg` and `sshcontrol` from `~/.gnupg` when present). `GIT_USER_NAME`, `GIT_USER_EMAIL` and `GIT_SIGNING_KEY` are read from `.env` with `grep`, not by sourcing it.

Outputs:

- Under the new owner's home (from `getent passwd`): `.ssh`, `.gnupg`, `.gitconfig`, `.database`, `.config/gh`, `.config/orchestrator/.env`, `.config/orchestrator/tokens/<owner>`, `.config/containers/storage.conf`, `.config/containers/containers.conf` and the checkout `credfeto-orchestrator`.
- System-wide: the user itself, its membership of `systemd-journal`, linger, the three unit files `credfeto-orchestrator-<owner>-<owner>.service`, `.timer` and `-failure.service` under `UNIT_DIR`, and `${POLKIT_RULES_DIR}/50-credfeto-orchestrator-<owner>.rules`. It removes `${SUDOERS_DIR}/<owner>` if present.

Exit codes: 0 on success, 1 from any `die`. Pre-flight problems are all printed first and then `Pre-flight checks failed`.

## How it works

The script sources `lib/core` (for `die`, `success`, `info`, `warn` and `is_ai_agent`) and `lib/systemd-units` (for `get_owner_home`, `systemd_service_name`, `install_systemd_units` and `UNIT_DIR`) via `SETUP_OWNER_DIR` from `BASH_SOURCE`; a failed source dies with `setup-owner: failed to source ...`. It defines its own `check_required_tools`, which replaces the `lib/core` one and requires `id useradd usermod passwd getent git loginctl runuser systemctl`.

Every command that must run as another user goes through `run_as <user> <home> <command...>`, which is `runuser -u <user> -- env HOME=<home> <command...>`. `runuser` keeps root's `HOME`, so the explicit `HOME` is what makes `git` and `gpg` read that user's configuration.

`main` then runs:

1. Argument parsing, the root check, the AI-session check, `check_required_tools` and `validate_source_config`.
2. `ensure_user_exists`: `useradd -m -s /bin/bash` then `passwd -l`, skipped if `id` finds the user.
3. `ensure_journal_group`: dies if the `systemd-journal` group does not exist (`is systemd-journald installed?`), otherwise `usermod -aG systemd-journal <owner>`, so the owner can read its own units' logs.
4. `enable_linger`: `loginctl enable-linger`.
5. `revoke_sudoers`: remove any sudoers file for the owner. The owner never needs `sudo`; the polkit rule below grants the only system rights it has.
6. `copy_dotfiles`: `copy_dotdir` for `.ssh`, `sync_gnupg`, `configure_git`, `copy_dotfile` for `.database`.
7. `copy_config_files`: `copy_config_dir` for `gh`, `copy_config_file` for `.env` and the owner's token.
8. `configure_podman_storage` (overlay with `fuse-overlayfs` if available, else `vfs`; graphroot under `~/work` when it is btrfs per `findmnt`) and `configure_podman_engine` (`cgroup_manager = "cgroupfs"`).
9. `clone_or_pull_repo`: clone, or reassert ownership when drift is found (#1300; a failed `chown` only warns) and `git pull --ff-only`, as the owner via `run_as`.
10. `install_owner_units`: `install_systemd_units <owner> <clone_dir> <owner>` from `lib/systemd-units` writes the three unit files and enables the timer (see [lib.md](../lib.md)).
11. `write_polkit_rule`: dies if `POLKIT_RULES_DIR` is missing (`is polkit installed?`), then writes a rule that lets the owner run `start`, `stop` and `restart` on its own `<service>.service` through `org.freedesktop.systemd1.manage-units`, and nothing else (not the timer, not other units). The file is rewritten on every run and set to `root:root`, mode 0644.

`sync_gnupg` exports the signing key with `export_signing_key`. When run through `sudo`, that runs `gpg --export-secret-keys` as `SUDO_USER` with `HOME=${SOURCE_HOME}`, because root's keyring does not hold the admin's key; on a real root login it runs `gpg` directly. The output is piped into `run_as <owner> <owner_home> gpg --homedir <owner>/.gnupg --import`.

Other tools used but not checked: `gpg`, `pkill`, `find`, `stat`, `cp`, `rm`, `chown`, `chmod`, `mktemp`, `mv`, `mkdir`, `touch`, `dirname`, `basename`, `grep`, `cut`, `tr`, `sed`, and the optional `findmnt` and `fuse-overlayfs`; `ssh` is implied by the SSH clone URL.

## Tests

`test/setup-owner.bats` (42 tests) loads `test_helper`, calls `setup_isolated_env`, points `SUDOERS_DIR`, `UNIT_DIR` and `POLKIT_RULES_DIR` at directories under `TEST_TMP`, unsets `CLAUDECODE` and `SUDO_USER`, and calls `source_setup_owner`. `cleanup_stubs` runs in teardown.

- `id` is a bash function exported with `export -f` that reports UID 1001 and user `testuser`; tests that need root or another answer redefine it. `getent` is a `make_stub 'exit 1'` (a failed lookup) unless a test overrides it with an exported function.
- `chown`, `useradd`, `passwd`, `usermod`, `loginctl`, `systemctl` and `pkill` are `make_stub` stubs that append their arguments to `${TEST_TMP}/calls.log`; `git` is `exit 0`. Tests assert on those log lines, on files written under `TEST_TMP`, and on their order (for example the ownership `chown` before the pull).
- `runuser` is a multi-line stub that exits 97 unless it is called as `-u <user> -- env HOME=...`, and otherwise runs the command. A test checks the stub itself rejects a call without `HOME`, so a `run_as` regression fails loudly instead of silently running as root.
- Several tests redefine `command` to hide `fuse-overlayfs`, or use a `make_stub` for `findmnt`. Any function a test overrides is removed with `unset -f` straight after `run`, so it cannot leak into later tests.

Covered: `check_required_tools` (including a missing `runuser` and no need for `sudo` or `visudo`), that no script calls `sudo` outside comments, `main`'s root refusal and usage error, `ensure_user_exists`, `ensure_journal_group` (new and existing users, missing group, `usermod` failure), `enable_linger`, `revoke_sudoers`, that `ensure_sudoers` no longer exists, `configure_podman_storage`, `configure_podman_engine`, `configure_git`, `copy_dotdir` (refresh and known_hosts backup and failure paths), `clone_or_pull_repo` (#1300 ownership drift, a failed `chown`, the clone with an explicit `HOME`, a failed pull), `install_owner_units` and `write_polkit_rule` (the allowed verbs, owner and mode, rewriting a stale rule, a missing directory). `lib/systemd-units` has its own suite, `test/systemd-units.bats`.

Not covered by any test: the `SUDO_USER` branch of `invoked_by_admin` (and so `SOURCE_HOME` resolution), `export_signing_key`, `sync_gnupg`, `validate_source_config`, `copy_dotfiles`, `copy_config_files`, `copy_dotfile`, `copy_config_file`, `copy_config_dir`, `main`'s AI-session refusal, and the "exists but is not a git repository" die of `clone_or_pull_repo`.

Run just this file with `bats test/setup-owner.bats`.

## Changing it safely

- [ ] `shellcheck setup-owner test/setup-owner.bats` is clean.
- [ ] `bats test/setup-owner.bats` passes, and `bats test/systemd-units.bats` if the unit installation changed.
- [ ] Mutation-check each new test: break the code it covers and confirm the test fails, then restore it.
- [ ] Never add `sudo`: the script runs as root, and a test fails if any script calls it. Run owner commands through `run_as`, never bare `runuser`, so `HOME` is set.
- [ ] Keep it in step with [teardown-owner](teardown-owner.md): any new unit file or system file written here must be removed there.
- [ ] Update `README.md`, `docs/deployment-and-setup.md` and `ai/local/debugging.instructions.md` (which cites this script's layout) if behaviour they describe changes.
- [ ] Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- [ ] The pre-commit hooks run the whole bats suite, so commits and pushes take minutes; run them in the background.

## Gotchas

- There is no `set -e`, `set -u` or `pipefail`; each command needs its own `|| die`. In `sync_gnupg` the pipeline `export_signing_key | run_as <owner> ... gpg --import || die` reports only the last command's status, so a failed export is noticed only if the import also fails. What `gpg --import` does with empty input was not checked.
- Running it from a root login rather than through `sudo` reads the staged material from root's own home, which normally has none, so `validate_source_config` fails. `sudo -i` or `su -` loses `SUDO_USER` the same way.
- Reading `.env` with `grep '^GIT_USER_NAME='` means an `export GIT_USER_NAME=...` line or an indented line is silently missed. Quote stripping differs per variable (`sed` for name and email, `tr` for the signing key).
- `configure_git` rewrites the whole `~/.gitconfig` on every run, but skips (leaving any existing file) when name or email is empty.
- Refresh semantics differ: `copy_dotdir` (`.ssh`) and `copy_config_dir` (`gh`) delete and recopy; `copy_config_file` always overwrites; `copy_dotfile` (`.database`) skips if the destination exists; `sync_gnupg` wipes `~/.gnupg` and kills the owner's `keyboxd` and `gpg-agent` (only when `GIT_SIGNING_KEY` is set in `.env`; otherwise it returns early and skips the GPG keyring sync). A destination-only `.ssh/known_hosts` is backed up and restored. The polkit rule and the unit files are rewritten every run.
- `copy_config_file` runs `chown -R` on the owner's whole `~/.config` each time.
- Order matters: `.ssh` is copied before the SSH clone in `clone_or_pull_repo`, the clone must exist before `install_owner_units` points the units at it, and the units must exist before the polkit rule refers to the service. On a first run the owner's `known_hosts` comes only from the admin's `~/.ssh/known_hosts` (copied with the directory). The script never adds GitHub's host key or sets `StrictHostKeyChecking`, so the SSH clone works only if the admin's `~/.ssh` already trusts github.com (or its ssh config disables the check).
- `ensure_journal_group` adds the group on every run, and group membership only applies to sessions started afterwards; with linger on, the owner's user manager may need restarting before `journalctl` shows the logs.
- `get_owner_home` is `getent passwd | cut`, so the `|| die` after `owner_home=$(get_owner_home ...)` almost never fires (the pipeline status is `cut`'s). The explicit empty-value check on the next line is what actually catches a missing user. In general, a `die` inside a `$(...)` would be swallowed, so callers must not rely on it.
- The `id` function override in the tests is exported, so it also affects any subprocess the test starts.
- GitHub API behaviour (listing lag, `gh project` having no single-item read, `-L` paging) does not affect this script. It makes no GitHub API calls; it only copies `gh`'s config and clones over SSH.
