# Shell Testing Instructions

[Back to Local Instructions Index](index.md)

> Load when: writing or modifying the `oneshot` or `loop` shell scripts, or any `*.bats` test under `test/`.

## Framework

- Tests use [bats-core](https://github.com/bats-core/bats-core) (the `bats` command), which is already installed.
- Tests live in the `test/` directory as `*.bats` files, with shared setup in `test/test_helper.bash`.
- Run the whole suite with `bats test/` from the repository root.
- Every behaviour added to a shell script must have a corresponding bats test before committing.

## Source-Guard Convention

The `oneshot` and `loop` scripts define all of their logic in functions and end with a source-guard:

```sh
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

This means the script runs `main` only when executed directly. When a test `source`s the
script, the guard is skipped, so all functions become available for unit testing without the
script driving a Claude session or entering the infinite loop. New scripts must follow the
same pattern: factor work into functions and gate execution behind this guard.

## Test Isolation

- Never touch the real filesystem outside the per-test temporary directory, and never make
  real network calls. Tests must be deterministic and runnable offline.
- Create a per-test temporary directory with `mktemp -d` rooted under `BATS_TEST_TMPDIR` so
  bats cleans it up automatically.
- Override every environment variable the scripts use to locate state, pointing each at the
  temporary directory before sourcing the script: `HOME`, `XDG_CONFIG_HOME`,
  `XDG_PROJECTS_DIR`, and `SESSION_BASE_DIR`.
- Re-assign `SESSION_BASE_DIR` (and any other derived path) after sourcing, because the script
  sets it from `HOME` at source time.

## Mocking External Commands

The scripts call external commands (`curl`, `gh`, `claude`, `git`, `sleep`, and the hashing
tools). Replace these with deterministic, offline stubs using one of two techniques:

- **PATH stub directory** — create an executable script in a directory that is prepended to
  `PATH`. Use this for commands invoked as subprocesses (`gh`, `git`, `claude`, `curl`,
  `sleep`) and for the tool-presence checks in `check_required_tools`.
- **Function override** — after sourcing the script, redefine a shell function with the same
  name to control its behaviour directly. Use this when you need to inspect arguments or vary
  the response per call.

Stubs must not perform real work: a `sleep` stub returns immediately, a `git` stub is a no-op,
and a `gh`/`curl` stub echoes canned JSON. This keeps the suite fast, deterministic, and free
of side effects.

### noexec constraint — stubs that must actually execute

`/tmp` is mounted `noexec` on this host. `BATS_TEST_TMPDIR` (and therefore `STUB_BIN` from
`setup_isolated_env`) lives in `/tmp`, so scripts placed there **cannot be executed as
subprocesses** — only PATH presence checks (`command -v`) work.

When a test needs to execute a stub as a real subprocess (not just check it is on `PATH`):

1. Call `make_repo_fixture_dir` — creates a temp directory inside `test/` (on the real
   filesystem, which IS executable) and stores the path in `REPO_FIXTURE_DIR`.
2. Write the stub into `${REPO_FIXTURE_DIR}` and `chmod +x` it.
3. Temporarily prepend `${REPO_FIXTURE_DIR}` to `PATH` before calling `run`.
4. Add `teardown() { cleanup_repo_fixtures; }` to the test file so fixtures are removed after
   each test.

## Static Analysis

- `shellcheck` must pass for the bash scripts (`shellcheck oneshot loop`) and for any `*.bash`
  test helper.
- `checkbashisms` does not apply because the scripts use `#!/bin/bash`.
