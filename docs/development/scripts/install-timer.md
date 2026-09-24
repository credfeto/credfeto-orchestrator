# install-timer

Generates and enables the systemd system-level service, failure-notifier and timer units that run `oneshot` on a fixed interval.

Back to the [development guide](../README.md).

## Purpose

`install-timer` writes three unit files under `/etc/systemd/system`, reloads systemd, then enables and starts the timer. The result is that `oneshot` runs as the invoking user every `ORCHESTRATOR_TIMER_INTERVAL`, even when nobody is logged in. It is run by a human administrator by hand, or by `setup-owner` as its last step (`sudo -u <owner> <clone>/install-timer --owner <owner>`, see `setup-owner` around line 513).

## Running it

```bash
./install-timer                 # one unit set per host user, runs "oneshot"
./install-timer --owner myorg   # owner-scoped unit set, runs "oneshot --owner myorg"
```

- The only option is `--owner <name>`. The value must match `^[a-zA-Z0-9][a-zA-Z0-9._-]*$`. Any other argument dies with `Unknown argument`.
- It must not run as root (`id -u` is checked) and must not run inside a Claude Code session (`is_ai_agent`, which tests `CLAUDECODE=1`). It calls `sudo` itself for every privileged step.
- Environment variables, all read with a default at the top of the script:
  - `ORCHESTRATOR_TIMER_INTERVAL` (default `30sec`) feeds `OnBootSec` and `OnUnitActiveSec`.
  - `ORCHESTRATOR_TIMEOUT_START_SEC` (default `6300`) is the service `TimeoutStartSec` (#1098).
  - `ORCHESTRATOR_TIMEOUT_STOP_SEC` (default `90`) is the service `TimeoutStopSec` (#1361).
  - `ORCHESTRATOR_NOTIFY_TIMEOUT_START_SEC` (default `60`) is the failure unit `TimeoutStartSec`.
- Inputs: `id -un`, `id -u`, `getent passwd <user>` (home directory, via `get_owner_home`), and the script's own directory (`REPO_DIR`), which is baked into `WorkingDirectory=` and `ExecStart=`.
- Outputs: `<UNIT_DIR>/<SERVICE_NAME>.service`, `<SERVICE_NAME>-failure.service` and `<SERVICE_NAME>.timer`, where `SERVICE_NAME` is `credfeto-orchestrator-<user>` or `credfeto-orchestrator-<user>-<owner>`. Existing files are overwritten without asking. Progress lines go to stdout.
- Exit codes: 0 on success, 1 from `die` on any failure. There is no `set -e`; every failure path is an explicit `|| die`.

## How it works

It sources nothing from `lib/`; `die`, `success`, `info` and `is_ai_agent` are local copies. Required tools (`check_required_tools`): `id`, `sudo`, `systemctl`, `git`, `getent`. The generated units also rely on absolute-path tools that are not checked at install time (`find`, `chown`, `timeout`, `pkill`, `ssh-agent`, `gpgconf`, `podman`, `xargs`).

1. At load time (also when sourced) it computes `REPO_DIR`, `CURRENT_USER`, `SERVICE_NAME` and `UNIT_DIR`, and calls `die` if any contains a newline or unsafe characters.
2. `main` parses `--owner`, then rejects root and AI-agent invocation, then runs `check_required_tools`.
3. With `--owner`, `main` appends it to `SERVICE_NAME` and re-validates the name.
4. `create_service_unit` resolves the home directory and UID, chooses the `ExecStop` line, builds the unit text and writes it with `write_unit_file` (`sudo tee`).
5. `create_failure_unit` writes the `OnFailure=` target that runs `notify-unit-failure` (see its guide).
6. `create_timer_unit` writes the timer (`WantedBy=timers.target`).
7. `main` runs `sudo systemctl daemon-reload`, `enable` and `start` on the timer.

The service unit is `Type=oneshot` with `OnFailure=`, `Delegate=cpu memory pids io`, `RuntimeDirectory=` and `Environment=` lines (`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `SSH_AUTH_SOCK`, `ORCHESTRATOR_SELF_UPDATE_MANAGED=1`). Its `ExecStartPre` steps run in this order: `.local` ownership heal, `REPO_DIR` ownership heal, `git fetch`, ff-only merge with stale-lock retry, ssh-agent and gpg-agent setup. Then come `ExecStart`, `ExecStop`, and the hardening directives. The comments inside the script explain the reason for each.

## Tests

`test/install-timer.bats` (26 tests). Setup uses `setup_isolated_env` and `source_install_timer` from `test/test_helper.bash`, plus `make_stub systemctl`, `setup_local_git_remote` and `advance_remote_main`, and `cleanup_stubs` in teardown.

- `id`, `getent` and `sudo` are exported bash functions, not PATH stubs, so that `$(...)` subshells inside the script see them. `id` reports `testuser` and UID 1001, `getent` returns `${TEST_TMP}/home`. `sudo` appends its arguments to `${TEST_TMP}/sudo.log` and, for `tee`, rewrites the destination to `${TEST_TMP}/units/<basename>`. Nothing real is written under `/etc`.
- Most tests run `main` and `grep` the generated file; unit content is never loaded into systemd, and no test runs `systemd-analyze`.
- Unusual: several tests extract an `ExecStartPre` command from the generated unit (`extract_execstartpre_cmd`, `generated_execstartpre_cmd`) and run it with `/bin/sh -c` against real temporary git repos and directories. These cover the stale-lock retry (#1298, with and without the age gate) and both ownership heals (#1232, #1300/#1302). The drift tests use `root` as the "wrong" owner, expect `Operation not permitted` under `LC_ALL=C`, and `skip` when the runner is root.
- `command id -un` is used to bypass the exported `id` function when a real account name is needed. `run_execstartpre_cmd` fails if the extracted command is empty, so a broken extraction cannot pass vacuously.
- Tests override `ORCHESTRATOR_*` variables after sourcing. That works because the `create_*` functions read the globals at generation time.
- Run only this file: `bats test/install-timer.bats`. Run one test: `bats -f "OnFailure" test/install-timer.bats`.

## Changing it safely

- [ ] `shellcheck install-timer test/install-timer.bats` is clean. The lists in `ai/local/*.instructions.md` name `install-timer` but do not cover the `.bats` file; run both.
- [ ] `bats test/install-timer.bats` passes.
- [ ] Mutation-check any new test: break the generated line (or the guard) and confirm the test fails, then restore it.
- [ ] Update `README.md`, `docs/deployment-and-setup.md` and `ai/local/debugging.instructions.md` where they describe the unit's behaviour.
- [ ] Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- [ ] The pre-commit hooks run the whole bats suite, so commit and push take minutes; run them in the background.
- [ ] Already-installed hosts only pick up a change when `install-timer` is re-run (`ai/local/debugging.instructions.md` says to re-run it to regenerate an older unit).

## Gotchas

- The unit body is one double-quoted bash string. Literal `"`, `$` and backticks inside it (including in comments) must be escaped, or they expand at install time or vanish. The tests grep for the exact resulting text.
- Ordering is tested: the `-+` `.local` heal must be the first `ExecStartPre` (`assert_local_ownership_heal_is_first_execstartpre`) and the `+-` `REPO_DIR` heal must precede the fetch (`assert_ownership_heal_before_selfupdate`). The two prefixes are deliberately textually different so greps cannot confuse them.
- `+` runs a step as root despite `User=`; `-` tolerates failure. The heals repeat `-print -quit` instead of using `\( -o \)` to avoid relying on systemd's Exec-line escape handling.
- Use absolute paths and values baked in at install time. A script comment says `%h` expands to the home of the user that launched systemd (root), and the CHANGELOG records the same for `%U` and `%u`.
- `ExecStop` fires at the end of every timer tick as well as at shutdown (per the script's comment). It must name the container as `orchestrator-<OWNER>` (the GitHub owner, as in `lib/podman`), not the Unix user. Without `--owner` it sweeps by the `orchestrator-` prefix.
- Do not add `KillMode=`, `StartLimitIntervalSec=` or `StartLimitBurst=` (tests assert their absence, reasoning in the script header). Do not add `PrivateTmp` or `NoNewPrivileges=yes` to the main unit. The strict settings belong only to the failure unit.
- All `--owner` units for one user share the same `REPO_DIR` checkout, which is why the lock deletion is age-gated (`-mmin +1`).
- `REPO_DIR` is only checked for newlines. It is not quoted in `ExecStart=`, so a path with spaces would presumably be split by systemd; this is untested.
- A re-run issues only `systemctl start`. Whether an already-running timer picks up a changed interval without a restart is not covered by the script or tests.
- GitHub API behaviour (list lag, `gh project`, `-L` paging) does not apply: the script makes no GitHub API calls. The units it writes run `git fetch`/`merge` and `oneshot`, which are documented elsewhere.
