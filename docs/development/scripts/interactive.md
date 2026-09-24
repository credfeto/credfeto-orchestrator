# interactive

`interactive` starts a live, terminal-attached Claude Code session inside the orchestrator's agent container, against the git checkout you run it from.

Back to the [development guide](../README.md).

## Purpose

`interactive` is the developer-machine counterpart to the unattended `oneshot` timer. It launches the same agent image, mounts, resource limits, secrets and GPG/SSH wiring as `oneshot`, but with your terminal attached and no fixed work item, so you drive the session yourself. It is run by a person, as themselves, from anywhere inside a GitHub-hosted git checkout. It is never run by the timer.

For the user-facing description see the `interactive` section of the [README](../../../README.md) and [agent-container.md](../../agent-container.md).

## Running it

```sh
cd ~/work/personal/some-repo
~/work/personal/credfeto-orchestrator/interactive
interactive --help
```

`main` accepts no arguments other than `-h` or `--help` (usage on stdout, exit 0). Any other argument prints usage to stderr and dies with `Unknown argument: <arg>` (exit 1).

Environment variables it reads:

- `INTERACTIVE_RULES_DIR`: the cs-template checkout to mount read-only at `/workspace/rules`. It defaults to `${WORK}/personal/cs-template`, where `WORK` is `XDG_PROJECTS_DIR` or `$HOME/work` (`lib/globals`). It must be an absolute path, because podman would treat a relative one as a named volume.
- `ORCHESTRATOR_IMAGE`: the agent image (default `ghcr.io/credfeto/development-agent:latest`, `lib/globals`).
- `XDG_CONFIG_HOME` (config and tokens), `XDG_STATE_HOME` (per-repo state under `orchestrator/<owner>/<repo>`) and `XDG_RUNTIME_DIR` (the scratch directory, the generated CLAUDE.md and the GPG public-key directory, falling back to `/tmp`).
- `GH_HOST`, `SSH_AUTH_SOCK` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW`: read from your shell (the last with a default of 100000 from `lib/globals`).

Files it reads or writes:

- Reads the checkout's `.git/config`, hooks directory, `.ai-instructions` and any `.claude/settings*.json` or `.mcp.json`.
- Creates `$XDG_CONFIG_HOME/orchestrator/.env` (mode 600) and `tokens/<owner>` (mode 600) on first run only; existing files are never rewritten.
- Creates the shared Claude state directories (`sessions`, `session-env`, `plans`, `cache`, `backups`) and `orchestrator-cache/global` under `ORCHESTRATOR_STATE_DIR/<owner>/<repo>`.
- Creates temporary files and podman secrets that are removed when the session ends (`cleanup_claude_invocation_tmpfiles`).

Exit status: the status podman returned for the session, `0` for `--help`, and `1` for every `die`. Unlike `oneshot` it takes no lock, and it clears every Discord webhook variable after loading `.env`, so failures are reported only at your terminal.

## How it works

1. Source `lib/globals`, `lib/core`, `lib/git`, `lib/github`, `lib/github-status`, `lib/fingerprints`, `lib/state`, `lib/prompts`, `lib/workflow-board`, `lib/discord` and `lib/podman`, in that order. Each `source` has a dependency-free `FATAL` fallback, because `die` does not exist until `lib/core` has loaded. Which functions from `lib/github`, `lib/github-status`, `lib/fingerprints`, `lib/state` and `lib/workflow-board` `interactive` reaches (directly or through `lib/podman` and `lib/discord`) is not obvious from `main`; that is not verified here.
2. Set `PRUNE_DANGLING_IMAGES=0` and `PODMAN_REPLACE_CONTAINER=0`, so the launch code never prunes your image store or `--replace`s a live container.
3. `main` runs `migrate_legacy_orchestrator_state`, then refuses a non-TTY (`terminal_available`), runs `check_interactive_tools` and checks that `INTERACTIVE_RULES_DIR` is absolute.
4. `resolve_repo_dir` and `resolve_repo_full` find the checkout and its `owner/repo`; each is followed by an explicit `|| exit 1` because `die` inside a command substitution only exits the subshell. `set_repo_context` then points the per-repo globals at the checkout and rules directory.
5. Host-side pre-flights that run before the image pull: `check_repo_remotes`, `check_repo_claude_config`, `check_rules_checkout`.
6. `bootstrap_orchestrator_config` (first-run `.env` and token), `load_env_config`, then the five `DISCORD_WEBHOOK_URL*` variables are blanked, `require_container_gh_token`, `load_checkout_git_identity`, `validate_config`, `check_signing_agents` and `preload_ssh_keys`.
7. `find_ai_instructions`, `host_to_container_path` and `build_interactive_claude_md` produce the CLAUDE.md content.
8. `git_metadata_digest` records the digest of `.git/config` and the hooks directory, then `invoke_claude_interactive` runs the session (`ensure_agent_container_ready`, `prepare_claude_container_args`, `--tty`, `podman run`). The container is named `interactive-<owner>-<repo>` and runs `claude --model opusplan` with `--add-dir` for the repo, rules and scratch paths.
9. `warn_if_git_metadata_changed` warns if the session changed `.git/config` (other than `branch.*` keys) or the hooks; `main` returns podman's exit status.

External tools: `git jq podman gh claude ssh-add awk gpg gpg-connect-agent gpgconf` and `sha256sum` or `shasum` (`check_interactive_tools`). It does not need `curl`, `flock` or `timeout`.

## Tests

The tests are in `test/interactive.bats`, 81 tests covering the `lib/git`, `lib/core`, `lib/prompts` and `lib/podman` functions that `interactive` relies on, and `main` itself. Run just this file with:

```sh
bats test/interactive.bats
```

It takes about 20 seconds. Setup calls `setup_isolated_env` and `source_interactive` from `test/test_helper.bash`; the latter sources the script (the source guard stops `main` running) and calls `seed_test_repo_context`. Teardown is `cleanup_stubs` only, because checkouts are created under `TEST_TMP`, not in the repository tree.

How commands are faked:

- PATH stubs written with `make_stub` and `make_stub_multiline` (`gh`, `claude`, `gpg`, `curl`, `podman`, and so on), which live in `STUB_BIN`.
- File-local helpers: `make_git_config_stub` (answers `git -C <dir> config --get` from `GITSTUB_*` variables), `make_interactive_podman_stub` (records podman arguments in `podman_args`, `podman_secret` and `podman_image`, exits with `PODMAN_STUB_EXIT`), `make_git_checkout`, `make_split_identity_checkout`, `setup_interactive_run` and `setup_main_run`.
- Real git is used for the checkout fixtures (offline), except in the tests that replace `git` with `make_git_config_stub`.
- Shell function overrides for things a test cannot really provide: `terminal_available`, `check_signing_agents`, `preload_ssh_keys`, `add_gpg_podman_args`, `stop_ssh_agent`, `hash_sha256` and `notify_discord_claude_error`.

Unusual points: the file needs bats 1.5.0 (`bats_require_minimum_version`), disables three shellcheck rules for the `@test` subshell style, and its `main` tests `cd` into a fixture checkout. `check_signing_agents` and `preload_ssh_keys` are overridden in `setup_main_run` because a test cannot create a live agent socket; they have their own tests. There is no test that pulls or prunes a real image store, and the pull, fallback and leftover-container behaviour of `ensure_agent_container_ready` is covered by `test/oneshot.bats` through `invoke_claude` (for example the `#1090` tests), not here.

## Changing it safely

- [ ] `shellcheck interactive` is clean (no new disables without a comment saying why); also run `shellcheck test/interactive.bats`.
- [ ] Run `bats test/interactive.bats`.
- [ ] Mutation-check any new test: break the code it covers, see the test fail, then restore it.
- [ ] Update the `interactive` section of `README.md`, [agent-container.md](../../agent-container.md) and `docs/deployment-and-setup.md` if behaviour, requirements or first-run steps change; also this guide.
- [ ] Add a changelog entry with `dotnet changelog`; never edit `CHANGELOG.md` by hand.
- [ ] The pre-commit hooks run the whole bats suite, so a commit or push takes minutes: run them in the background and poll for completion.
- [ ] Editing `build_interactive_claude_md` changes text the agent reads; see `ai/local/shell-testing.instructions.md` first.

## Gotchas

- Ordering is load-bearing. The webhook variables are blanked after `load_env_config` (which reads them from `.env`) and before anything that can call `notify_discord_*`; `load_checkout_git_identity` runs after `load_env_config` and before `validate_config`, so a `.env` with no `GIT_*` keys passes. Tests: `main never posts a launch failure...`, `main blanks the four per-category Discord webhooks...`, `validate_config accepts a .env without GIT_*...`.
- The host-side refusals (`check_repo_remotes`, `check_repo_claude_config`, `check_rules_checkout`, `check_signing_agents`) deliberately run before the image pull, because the container entrypoint refuses the same conditions, but only after the pull and with container paths in its message.
- The script has no `set -e`. Every `die` is explicit, and a `die` in a command substitution needs the `|| exit 1` seen in `main`.
- `main` records a digest of the hooks directory before the session and compares after: an empty digest would pass vacuously, so it dies if the digest fails (`git_metadata_digest fails rather than returning an empty digest...`).
- `PODMAN_REPLACE_CONTAINER=0` means a second launch for the same checkout fails on the container name rather than killing the first session. There is no per-owner lock.
- Do not add an `EXIT`-trap command such as `stop_ssh_agent`: it would kill your own long-lived ssh-agent. A test asserts it is not installed.
- Podman secret names come from the container name (`claude-oauth-interactive-<owner>-<repo>`), so they cannot clash with a running `oneshot`.
- Tests that call `die` paths need `run` (the `exit` would otherwise end the test); tests that inspect variables set by `invoke_claude_interactive` call it directly.
- GitHub API behaviour (list lag after writes, `gh project` having no single-item read, `gh ... -L` paging at 100 items and being capped) does not affect this script. Its only GitHub call is `gh auth token` during first-run bootstrap, which reads a local credential and lists nothing. The agent session it starts can hit those limits, but the guidance for that belongs to the AI instructions the session loads, not to this script.
