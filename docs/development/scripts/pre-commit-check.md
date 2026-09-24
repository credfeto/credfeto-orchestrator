# pre-commit-check

A POSIX shell script that checks the current branch is not behind its remote, then finds the active `pre-commit` hook and runs it with `--all-files`.

Back to the [development guide](../README.md).

## Purpose

It lets the full pre-commit hook chain be exercised on demand against the current checkout, without making a real commit, and refuses to do so on a stale branch (a pass on an out-of-date tree proves little). `ai/global/git.instructions.md` uses it as the baseline gate before starting work, and as the final step of a rebase.

## Running it

```sh
pre-commit-check
```

There are no options or arguments: the script never reads `"$@"`, so anything passed is silently ignored. Run it from inside the repository; the hook runs in the current working directory.

Environment: the script defines none of its own. It relies on git's own configuration (`core.hooksPath` at system and global level, `GIT_CONFIG_SYSTEM` and `HOME`, which the tests use to isolate it), and colours its output only when stdout/stderr is a terminal.

Output uses three inlined helpers (the script cannot source `lib/`):

- `info` prints `→ Running <hook> --all-files` to stdout.
- `success` prints `✓ Pre-commit checks passed` to stdout.
- `die` prints `✗ <message>` to stderr and exits 1.

Exit codes: 0 when the hook passes; 1 for every failure (fetch failed, behind, no hook found, hook failed). The hook's own exit status is not passed through: a failing hook gives `pre-commit hook failed` and exit 1.

## How it works

1. If `git remote get-url origin` succeeds, run `git fetch origin --quiet` (`die` on failure). With no `origin` (a scratch repo) the whole up-to-date check is skipped.
2. Work out the default branch from `refs/remotes/origin/HEAD` (`sed` strips the prefix), falling back to `main`.
3. If the branch has an upstream (`@{upstream}`), count `HEAD..<upstream>` with `git rev-list --count`; more than 0 is `Local branch is N commit(s) behind <upstream> - pull/rebase first`.
4. Do the same against `origin/<default branch>`, unless that ref does not exist or is already the branch's own upstream. This catches a feature branch that is up to date with its own upstream but stale against main.
5. `hook_in` returns `<dir>/pre-commit` when it exists and is executable. It is tried in order for `$(git rev-parse --absolute-git-dir)/hooks`, then `git config --system --get core.hooksPath`, then `git config --global --get core.hooksPath`. The first hit wins.
6. No hit is `die "No pre-commit hook found in the repo's hooks folder, system hooksPath, or global hooksPath"`. Otherwise `info`, run `"$HOOK" --all-files`, and `success` or `die`.

External tools: `git`, `sed`, and a `pre-commit` hook file that accepts `--all-files`. A branch only being ahead of its upstream is fine; only "behind" is an error.

Shipping: the Dockerfile in `containers/base/development-full/` copies it to `/usr/local/bin/pre-commit-check` (root:root, 0755) and the sanity loop checks presence and the executable bit only. In the container `/etc/gitconfig` sets `core.hooksPath = /opt/git-global-hooks`, so the system level is normally what resolves when the repo has no hook of its own. It is on `claude-hooks/command-allowlist`, `Bash(pre-commit-check *)` is in `claude-settings.json` (`test/command-allowlist-parity.bats` keeps the two in step), and `enforce-background-for-long-running-commands` blocks it unless `run_in_background: true` (tests "pre-commit-check without run_in_background is blocked" and "a path-qualified pre-commit-check invocation is blocked" in `test/enforce-background-for-long-running-commands.bats`). `install-claude-hooks` does not install it on a host.

## Tests

`test/pre-commit-check.bats` has six tests: no hook anywhere, the repo hook run with `--all-files` and the success message, a failing hook, the system `hooksPath` fallback, the global `hooksPath` fallback, and a non-executable repo hook being skipped for the global one.

- `setup` runs `setup_isolated_env`, sets `GIT_CONFIG_SYSTEM=/dev/null` so the host's `/etc/gitconfig` cannot leak a `core.hooksPath` in, and runs `git init -q` on a repo under `${TEST_TMP}`. There is no `origin`, so the fetch and behind checks are skipped.
- Nothing is stubbed. The hooks are real small executable scripts written by the local `write_hook <path> <body>` helper, and git config is real, using the isolated `HOME` for global config and a file passed through `GIT_CONFIG_SYSTEM` for the system test.
- `run_script <dir>` (from `test/test_helper.bash`) runs the script with that working directory.

Run just this file:

```bash
bats test/pre-commit-check.bats
```

## Changing it safely

- Run `shellcheck containers/base/development-full/scripts/pre-commit-check`. The shebang is `#! /bin/sh`, so keep it POSIX (no bash arrays or `[[`).
- Run `bats test/pre-commit-check.bats`.
- Mutation-check any new test: break the code (for example remove the `-x` test in `hook_in` or the `die` after a failed hook) and confirm the test fails, then restore it.
- Update `containers/base/development-full/README.md` (the `pre-commit-check` bullet), `ai/global/git.instructions.md` and any other doc that describes the check order. The script has no help text.
- If it is renamed, update `Dockerfile`, `claude-hooks/command-allowlist`, `claude-settings.json` and `enforce-background-for-long-running-commands`.
- Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- The pre-commit hooks run the whole bats suite, so commits and pushes take minutes. Run them in the background. Running this script itself is just as slow, which is why the hook requires `run_in_background`.

## Gotchas

- The fetch, `@{upstream}` and default-branch checks are not covered by any test, because the test repo has no `origin`. To add one, `setup_local_git_remote` and `advance_remote_main` in `test/test_helper.bash` build a local bare remote and move it on.
- Arguments are ignored, so a typo such as `pre-commit-check --all` still runs the whole check.
- Without a network, and with an origin remote, the script dies at the fetch, before looking for a hook (the fetch only runs when an origin remote exists).
- The hook is always run with `--all-files`, on every file, not only the ones changed.
- Hook order is repo, then system, then global: a repo-level hook hides the global one entirely. A hook that exists but is not executable is skipped silently (test "a non-executable repo hook is skipped in favour of the global hooksPath").
- GitHub API behaviour: not affected. It only uses `git fetch` and local git plumbing, and never calls `gh` or the GitHub API.
