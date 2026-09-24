# notify-unit-failure

Posts a Discord alert, with a redacted journal excerpt, when an orchestrator systemd unit enters the failed state.

Back to the [development guide](../README.md).

## Purpose

`notify-unit-failure` is the `OnFailure=` handler for the orchestrator service. It runs as a separate systemd unit so it can still report when `oneshot` is too broken to send its own notifications, which is the case that went unnoticed for 19.5 hours in #1361. systemd runs it; `install-timer` generates the unit that calls it (`ExecStart=<repo>/notify-unit-failure <service>.service`).

## Running it

```bash
./notify-unit-failure credfeto-orchestrator-alice-alice.service
```

- One positional argument, the failed unit name. It is the only input besides the config file below.
- Config: `${XDG_CONFIG_HOME:-${HOME}/.config}/orchestrator/.env`, the same file `oneshot` uses. It reads the `DISCORD_WEBHOOK` key only, without sourcing the file: the last matching line wins, surrounding whitespace and one layer of quotes are stripped. The category webhooks (`DISCORD_WEBHOOK_BLOCKED` and so on) are ignored. Inline trailing comments on the line are not stripped.
- Other inputs: `journalctl -u <unit> -n 15 --no-pager` and `HOSTNAME`.
- Output: one HTTP POST of a Discord embed, made with `curl -sf --max-time 5`. Diagnostics go to stderr, where systemd captures them.
- Exit codes:
  - 1 only when no unit name is given.
  - 0 in every other case, deliberately: missing `.env`, missing `DISCORD_WEBHOOK`, a webhook that is not `https://`, and a failed POST each print a `notify-unit-failure:` message on stderr and exit 0.

## How it works

It sources nothing from `lib/` on purpose, because everything there assumes the orchestrator environment is intact. It has `set -e`. External tools: `grep`, `tail`, `cut`, `sed`, `tr`, `journalctl`, `curl`, and `jq` (optional).

1. Require the unit name, else stderr message and exit 1.
2. Locate `CONFIG_FILE`; if absent, message and exit 0.
3. Extract `WEBHOOK` with `grep | tail | cut | sed`; if empty, message and exit 0.
4. Require an `https://` prefix, so curl cannot read the value as an option.
5. Capture `CONTEXT` from `journalctl` (`|| true`); fall back to `(no journal output available)`.
6. Redact with one `sed -E` pass over these patterns: `gh[pousr]_`, `github_pat_`, `sk-ant-`, `xox[abprs]-`, the path of a Discord webhook URL, and `Bearer`/`Token`/`Authorization` followed by 12 or more token characters.
7. Truncate after redaction to `MAX_CONTEXT_CHARS` (900): keep the last 900 characters with a `...(truncated)...` prefix.
8. Build the payload with `jq -n --arg ...`. If `jq` is absent, print `jq unavailable` and hand-build a context-free JSON payload, restricting the unit and host names with `tr -cd`.
9. `curl` POST; on failure print `failed to post Discord alert` and continue. `exit 0`.

## Tests

`test/notify-unit-failure.bats` (9 tests). Setup: `setup_isolated_env` from `test/test_helper.bash`, `XDG_CONFIG_HOME` pointed at `${TEST_TMP}/config`, a hand-written `curl` stub, `make_stub journalctl`, and `cleanup_stubs` in teardown. The script is executed as a subprocess (`run "${SCRIPT}" my-unit.service`), not sourced.

- The `curl` stub is written directly into `${STUB_BIN}` and appends every argument, one per line, to `${TEST_TMP}/curl.log`. Assertions grep that log, so they see the JSON payload the script would have sent.
- `journalctl` is stubbed per test with the text to be redacted, or a 400-line loop to trigger truncation.
- The `jq unavailable` test replaces `PATH` with a directory of symlinks to only the tools the script needs (`grep sed cut tail tr bash env`) plus the two stubs, so `command -v jq` finds nothing. Emptying `PATH` would not prove the same thing. `bash` and `env` are needed because the stubs use `#!/usr/bin/env bash`.
- Covered: successful post, missing `.env`, missing key, non-https value, no argument (status 1), redaction of a `ghp_` token and an `sk-ant-` key, truncation, and the no-`jq` fallback. Not covered by any test: the `github_pat_`, `xox`, Discord URL and bare `Bearer`/`Token` patterns, a `curl` failure, and `jq` present but failing.
- Run only this file: `bats test/notify-unit-failure.bats`.

## Changing it safely

- [ ] `shellcheck notify-unit-failure test/notify-unit-failure.bats` is clean. The lists in `ai/local/*.instructions.md` do not include this script, so run it explicitly.
- [ ] `bats test/notify-unit-failure.bats` passes.
- [ ] Mutation-check any new test: for example remove one `sed -e` redaction line and confirm the matching test fails.
- [ ] Update the "Unit-failure alerts" section of `README.md` if behaviour changes (`docs/discord-notifications.md` does not currently mention this script; consider whether it should). Also check the unit `install-timer` generates for it (`create_failure_unit`) and its `test/install-timer.bats` tests.
- [ ] Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- [ ] The pre-commit hooks run the whole bats suite, so commit and push take minutes; run them in the background.

## Gotchas

- It must never fail silently. Every early exit prints a reason on stderr. The notifier unit has no `OnFailure=` of its own, so a silent failure here means no alert anywhere.
- `set -e` interaction: `grep` in the webhook pipeline is not the last stage and there is no `pipefail`, so a missing key does not abort. `journalctl` is guarded with `|| true`, and the `jq` check sits inside an `if`. By reading the code, `PAYLOAD=$(jq ...)` is not guarded, so a `jq` that exists but fails would abort under `set -e` before `curl` (unhandled and untested).
- Redact before truncating, so a secret cannot survive by sitting past the cut. Keep that order if you edit it.
- Truncation uses `${CONTEXT: -${MAX_CONTEXT_CHARS}}`; the space before the minus is required in bash.
- The 900-character budget and the 5-second `--max-time` deliberately mirror `lib/discord`. Discord rejects an embed description over its cap with a 400 and the whole alert is lost.
- The webhook line is parsed with a regex, so `export DISCORD_WEBHOOK=...` does not match, and only `DISCORD_WEBHOOK` is honoured, not the per-category keys.
- The generated unit (`create_failure_unit` in `install-timer`) sets `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=yes` and an empty `CapabilityBoundingSet`, and its comment says it only runs grep, journalctl, jq and curl. Any new tool or write location must work under those settings; the script cannot write under `/home` or the system directories.
- If you add a tool the script needs, also add it to the symlink list in the no-`jq` test, or that test will start failing for the wrong reason.
- systemd behaviour: a hung `curl` would leave the unit `activating` and later `OnFailure=` activations would coalesce into it, hence `--max-time 5` here and `TimeoutStartSec` in the unit.
- GitHub API behaviour (list lag, `gh project`, `-L` paging) does not apply: the script talks only to the Discord webhook, never to GitHub.
