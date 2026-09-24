# loop

`loop` is a foreground wrapper that updates its own checkout from `main`, runs `oneshot`, sleeps 300 seconds and repeats forever.

Back to the [development guide](../README.md).

## Purpose

`loop` is for running the orchestrator continuously from a terminal or a process supervisor without the systemd timer that `install-timer` sets up. A person (or a supervisor) starts it, and it never returns on its own. It is not used by the production timer units: `install-timer` does not reference it, The root README does not describe it, and `docs/` mentions it only in passing (`docs/development/README.md`, `docs/discord-notifications.md`). Besides this guide, its documentation is the header comment in the script.

## Running it

```sh
~/work/personal/credfeto-orchestrator/loop
```

It takes no arguments (`main "$@"` ignores them) and reads no environment variables of its own, except that `is_ai_agent` reads `CLAUDECODE`. The 300 second delay is a plain assignment, `SLEEP_SECONDS=300`, so it cannot be changed from the environment. `oneshot` inherits the caller's environment, so anything `oneshot` reads (see [oneshot.md](../../oneshot.md)) applies.

Inputs and outputs:

- It reads and writes nothing itself. The git commands run against the directory containing the script (`SCRIPT_DIR`, resolved with `BASH_SOURCE`), and `oneshot` is run from that same directory.
- Progress goes to the terminal through `info` and `success` from `lib/core` (stdout) and `warn` and `die` (stderr). Each iteration prints an "updating scripts" line, a "running oneshot" line and a "complete, sleeping 300s" line.

Exit status: it never exits normally. It exits `1` when `lib/core` cannot be sourced (a `FATAL` message), when `oneshot` is missing or not executable, when it is run inside a Claude Code session, or when `git switch main` fails. It otherwise runs until it is killed. `oneshot`'s own exit status is not checked.

## How it works

1. Resolve `SCRIPT_DIR` from `BASH_SOURCE[0]` and source `lib/core`, exiting with a dependency-free `FATAL` message if that fails. It sources nothing else, in particular not `lib/globals`.
2. `main` dies unless `${SCRIPT_DIR}/oneshot` is executable.
3. `main` dies if `is_ai_agent` is true, that is when `CLAUDECODE` is `1`.
4. Repeat forever, counting iterations:
   1. `update_scripts` runs `git -C "${SCRIPT_DIR}" switch main`, dying if that fails, then `timeout 60 git -C "${SCRIPT_DIR}" pull`, which only warns if the pull fails or times out.
   2. Run `"${SCRIPT_DIR}/oneshot"`.
   3. Print `success` and `sleep 300`.

External tools: `git`, `timeout` (from coreutils) and `sleep`, plus whatever `oneshot` needs. Unlike `oneshot`, `loop` does not check for them with `require_tools`, so a missing `timeout` would show up as a failed pull warning, not a clear error.

## Tests

The tests are in `test/loop.bats`, 8 tests. Run just this file with:

```sh
bats test/loop.bats
```

It runs in about a second. Setup calls `setup_isolated_env` and teardown calls `cleanup_stubs` and `cleanup_repo_fixtures`, all from `test/test_helper.bash`.

There are two styles:

- Subprocess tests use the file-local `run_loop_in <dir> [env args]`, which runs `bash ./loop` from a fixture directory. The fixture comes from `make_repo_fixture_dir`, which creates `test/.fixture.XXXXXX` inside the repository tree (some sandboxes do not honour the execute bit under the system temp directory) and copies `lib/` into it. The tests copy `loop` in, and add or omit a `oneshot` stub, to reach each early `die`: `loop dies when oneshot is not executable`, `loop refuses to run inside a Claude Code session (CLAUDECODE=1)` and `loop dies loudly when lib/core cannot be sourced`. Note the `oneshot` check comes before the `CLAUDECODE` check, which is why the second test creates an executable `oneshot`.
- Unit tests call `source_loop`, which sources the script without running `main` (the source guard), then call `is_ai_agent` and `update_scripts` directly with `git` (and, in one test, `timeout`) faked by `make_stub`. The `git` stub matches on `*switch*` and `*pull*` in `"$*"`.

Not covered: the `while true` body itself (the iteration counter, running `oneshot`, the `sleep`). Nothing in `loop.bats` stubs `sleep` or runs an iteration.

## Changing it safely

- [ ] `shellcheck loop` is clean, and `shellcheck test/loop.bats` too.
- [ ] Run `bats test/loop.bats`.
- [ ] Mutation-check any new test: break the code it covers, see the test fail, then restore it.
- [ ] Update `ai/local/shell-testing.instructions.md` if the sourcing or source-guard conventions change, and this guide. The root README does not describe `loop`; `docs/development/README.md` links to this guide.
- [ ] Add a changelog entry with `dotnet changelog`; never edit `CHANGELOG.md` by hand.
- [ ] The pre-commit hooks run the whole bats suite, so a commit or push takes minutes: run them in the background and poll for completion.

## Gotchas

- Never let a test reach the real loop body against the real repository. In an earlier incident (#1185 review, quoted in the test and in `ai/local/shell-testing.instructions.md`) a fixture with no `lib/` let `loop` fall through into the `while` loop, which then ran `git switch main` and `git pull` against the enclosing repository every 300 seconds for hours. The `FATAL ... exit 1` on the `source` line and the `GIT_CEILING_DIRECTORIES` export in `setup_isolated_env` both exist for this. Any new test of the loop body must use a fixture with its own `.git`, or a `git` stub, and must stub `sleep`.
- There is no `set -e`. That is why the `source` line has an explicit `|| { ...; exit 1; }`, why `git switch` is followed by `|| die`, and why a failing `oneshot` is silently ignored: the loop prints "complete" and sleeps as normal. If you want a failure to stop the loop, that is a behaviour change.
- The two `git` failure modes are deliberately different. A failed switch dies (the checkout is in an unexpected state, and running stale or wrong-branch code is worse than stopping); a failed or hung pull only warns (`#1104`), because a network stall must not stop the loop and there is no timer to recover it.
- `SCRIPT_DIR` must come from `BASH_SOURCE[0]`, not `$0`, or `source_loop` in the tests resolves the bats runner's directory instead.
- The `git pull` is a plain `git pull` with whatever configuration the checkout has; behaviour with a diverged `main` depends on the checkout's git config (`pull.rebase` / `pull.ff`): on git 2.33+ with neither set a non-fast-forward `git pull` fails, which `loop` reports with the 'git pull failed or timed out' warning before carrying on; the container's system gitconfig sets `pull.rebase = true` but `loop` normally runs on the host. No test covers it and it was not probed.
- `loop` runs `oneshot` with no arguments. `oneshot` takes a per-owner `flock` lock (`_global.lock` when no owner is given) and exits 0 if another instance holds it. Its stale-checkout refusal (`git_commits_behind`) only applies when `ORCHESTRATOR_SELF_UPDATE_MANAGED` is set, which `install-timer`'s unit does and `loop` does not; a comment in `oneshot` says this looser policy for `loop` is deliberate.
- GitHub API behaviour (list lag after writes, `gh project` having no single-item read, `gh ... -L` paging at 100 items and being capped) does not affect `loop`. It makes no GitHub API calls: it runs only `git` against the checkout's remote and starts `oneshot`, which is where those points apply.
