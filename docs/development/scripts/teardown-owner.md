# teardown-owner

Stops and disables an owner's orchestrator timer, and removes its three unit files and its polkit rule.

Back to the [development guide](../README.md).

## Purpose

`teardown-owner` reverses the systemd and polkit part of `setup-owner` for one owner. It is run by hand, as root, by a human administrator; no script in the repository calls it. It leaves the owner's Unix account, home directory and checkout in place, so a later `setup-owner --owner <name>` run reinstalls the units against the same account.

## Running it

```bash
sudo ./teardown-owner --owner myorg   # removes credfeto-orchestrator-myorg-myorg.* and the polkit rule
```

- `--owner <name>` is required. The value must match `^[a-z][a-z0-9_-]*$`, the same rule `setup-owner` applies. A missing value dies with `--owner requires a value`, any other argument with `Unknown argument`.
- It must run as root (`id -u` is checked) and must not run inside a Claude Code session (`is_ai_agent`, `CLAUDECODE=1`). It never calls `sudo`.
- Environment variables: `UNIT_DIR` (default `/etc/systemd/system`, from `lib/systemd-units`) and `POLKIT_RULES_DIR` (default `/etc/polkit-1/rules.d`). Both exist so tests can point the removals at a temporary directory.
- It removes `<UNIT_DIR>/<name>.service`, `<name>.timer` and `<name>-failure.service`, where `<name>` is `credfeto-orchestrator-<owner>-<owner>` (from `systemd_service_name`), and `<POLKIT_RULES_DIR>/50-credfeto-orchestrator-<owner>.rules`.
- Exit codes: 0 on success, 1 from `die` (bad argument, not root, AI session, failed `rm` or `daemon-reload`). There is no `set -e`.

## How it works

It sources `lib/core` (for `die`, `info`, `success` and `is_ai_agent`) and `lib/systemd-units` (for `systemd_service_name` and `UNIT_DIR`), so the unit name it removes is derived by the same function `setup-owner` used to install it.

1. `main` parses `--owner`, rejects AI-agent invocation, then rejects a non-root caller.
2. `systemctl stop` and `systemctl disable` on the timer, each with `2>/dev/null || true`, so a timer that was never installed is not an error.
3. `rm -f` of the service, timer and failure unit files (`|| die`).
4. `rm -f` of the polkit rule (`|| die`).
5. `systemctl daemon-reload` (`|| die`), then `success`.

Only the timer is stopped and disabled. The service itself is not stopped, so a run already in progress is left to finish. The failure unit has no `[Install]` section, so it is only removed as a file.

## Tests

`test/teardown-owner.bats` (14 tests). Setup: `setup_isolated_env`, a `systemctl` PATH stub that logs to `${TEST_TMP}/systemctl.log`, an exported `id` function that reports UID 0, and `UNIT_DIR`/`POLKIT_RULES_DIR` pointed at directories under `${TEST_TMP}`. Each test calls `source_teardown_owner`; `cleanup_stubs` runs in teardown.

- `create_owner_units` writes placeholder unit files and a polkit rule, so the tests check real file removal rather than a logged command line.
- Covered: removal of all four files, stop/disable before `daemon-reload`, other owners' units and rules (and the home and checkout) left alone, a repeat run on already-removed files, `stop`/`disable` failures tolerated, a failing `daemon-reload`, the root and AI-session refusals, the argument errors, and that `sudo` is never invoked.
- Run only this file: `bats test/teardown-owner.bats`.

## Changing it safely

- [ ] `shellcheck teardown-owner test/teardown-owner.bats` is clean.
- [ ] `bats test/teardown-owner.bats` passes.
- [ ] Mutation-check any new test: break the script line it covers and confirm the test fails, then restore it.
- [ ] Keep it in step with `setup-owner` and `lib/systemd-units`: any new unit file or system file they write must be removed here.
- [ ] Update `README.md` and `docs/deployment-and-setup.md` if behaviour changes.
- [ ] Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- [ ] The pre-commit hooks run the whole bats suite, so commit and push take minutes; run them in the background.

## Gotchas

- The `2>/dev/null || true` on `stop` and `disable` hides every error from those two commands, not just "unit not found". The later `rm -f` and `daemon-reload` are the only steps that can fail the run.
- `rm -f` succeeds when files are absent, so a repeat run or a wrong `--owner` value reports success while removing nothing. Check the value against the installed name (`systemctl list-timers "credfeto-orchestrator-*"`).
- Stopping the timer does not stop a running `.service` or remove its container; the `ExecStop` cleanup only runs when the service stops.
- Argument errors are reported before the AI-session and root checks, because arguments are parsed first.
- GitHub API behaviour (list lag, `gh project`, `-L` paging) does not apply: the script makes no GitHub calls.
