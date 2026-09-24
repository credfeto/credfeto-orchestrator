# uninstall-timer

Stops and disables the systemd timer created by `install-timer` and removes its three unit files.

Back to the [development guide](../README.md).

## Purpose

`uninstall-timer` reverses `install-timer` for the current user, or for one `--owner` variant. It is run by hand by a human administrator; no script in the repository calls it (a search finds its name only in its own file, its bats file, `test/test_helper.bash`, the changelog and docs).

## Running it

```bash
./uninstall-timer                 # removes credfeto-orchestrator-<user>.*
./uninstall-timer --owner myorg   # removes credfeto-orchestrator-<user>-myorg.*
```

- The only option is `--owner <name>`, validated with `^[a-zA-Z0-9][a-zA-Z0-9._-]*$`. Anything else dies with `Unknown argument`; a missing value dies with `--owner requires a value`.
- It refuses to run inside a Claude Code session (`is_ai_agent`, `CLAUDECODE=1`). Unlike `install-timer` it has no root check, so running it as root is not rejected.
- No environment variables of its own. It reads `id -un` (`CURRENT_USER`) and uses the hard-coded `UNIT_DIR=/etc/systemd/system`.
- It removes `<SERVICE_NAME>.service`, `<SERVICE_NAME>.timer` and `<SERVICE_NAME>-failure.service` with `sudo rm -f`, then runs `sudo systemctl daemon-reload`.
- Exit codes: 0 on success, 1 from `die` (bad argument, AI session, missing tool, failed `rm` or `daemon-reload`). Progress lines go to stdout, errors to stderr. There is no `set -e`.

## How it works

It sources nothing from `lib/`; `die`, `success`, `info` and `is_ai_agent` are local copies. `check_required_tools` needs `id`, `sudo` and `systemctl`.

1. At load time it computes and validates `CURRENT_USER`, `SERVICE_NAME` (`credfeto-orchestrator-<user>`) and `UNIT_DIR`.
2. `main` parses `--owner`, rejects AI-agent invocation, then runs `check_required_tools`.
3. With `--owner`, `main` appends it to `SERVICE_NAME` and re-validates.
4. `sudo systemctl stop <name>.timer` and `sudo systemctl disable <name>.timer`, each with `2>/dev/null || true`, so a timer that was never installed is not an error.
5. `sudo rm -f` of the service, timer and `-failure.service` files. This step is guarded by `|| die`.
6. `sudo systemctl daemon-reload` (`|| die`), then `success`.

Only the timer is stopped and disabled. The service itself is not stopped, so a run already in progress is left to finish, and `RuntimeDirectory` state is not touched. The failure unit has no `[Install]` section, so it is only removed as a file.

## Tests

`test/uninstall-timer.bats` (10 tests). Setup: `setup_isolated_env`, `make_stub systemctl 'exit 0'`, `source_uninstall_timer`, and `cleanup_stubs` in teardown.

- `id` is an exported function that prints `testuser`. `sudo` is an exported function that only appends its arguments to `${TEST_TMP}/sudo.log`; it never runs `rm` or `systemctl`. The assertions are `grep`s on that log (for example `rm -f.*credfeto-orchestrator-testuser.service`). The `systemctl` PATH stub exists so `check_required_tools` passes on hosts without systemd (see the CHANGELOG entry about the stub).
- One test overrides `command` so `command -v systemctl` fails, to exercise `check_required_tools`.
- `uninstall-timer issues stop and disable before removing unit files` compares log line numbers to prove stop precedes `rm -f`, which precedes `daemon-reload`.
- No test asserts that `-failure.service` is removed: the `rm -f` greps match the main service and timer paths on the same log line, so deleting the failure path from the script would not fail any test.
- Run only this file: `bats test/uninstall-timer.bats`.

## Changing it safely

- [ ] `shellcheck uninstall-timer test/uninstall-timer.bats` is clean. The lists in `ai/local/*.instructions.md` do not include `uninstall-timer`, so run it explicitly.
- [ ] `bats test/uninstall-timer.bats` passes.
- [ ] Mutation-check any new test: break the script line it covers and confirm the test fails, then restore it.
- [ ] Update `README.md` and `docs/deployment-and-setup.md` (which describes it in one line) if behaviour changes.
- [ ] Keep it in step with `install-timer`: any new unit file that script writes must be removed here.
- [ ] Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- [ ] The pre-commit hooks run the whole bats suite, so commit and push take minutes; run them in the background.

## Gotchas

- Order: stop, disable, remove files, then reload. The test compares the positions of `systemctl stop`, `rm -f` and `daemon-reload` in the sudo log; `disable` is not compared.
- The `2>/dev/null || true` on `stop` and `disable` hides every error from those two commands, not just "unit not found". The later `rm -f` and `daemon-reload` are the only steps that can fail the run.
- `rm -f` succeeds when files are absent, so a repeat run or a wrong `--owner` value reports success while removing nothing. Check the `--owner` value against the installed name (`systemctl list-timers "credfeto-orchestrator-*"`).
- The name is built from `id -un` at load time, so it removes the units for the user who runs it; run it as the same account that ran `install-timer`.
- Stopping the timer does not stop a running `.service` or remove its container; the `ExecStop` cleanup only runs when the service stops.
- Argument errors are reported before the AI-session check and before tool checks, because arguments are parsed first.
- GitHub API behaviour (list lag, `gh project`, `-L` paging) does not apply: the script makes no GitHub calls.
