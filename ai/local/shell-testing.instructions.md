# Shell Testing Instructions

[Back to Local Instructions Index](index.md)

> Load when: writing or modifying the `oneshot` or `loop` shell scripts, or any `*.bats` test under `test/`.

## Framework

- Tests use [bats-core](https://github.com/bats-core/bats-core) (the `bats` command), which is already installed.
- Tests live in the `test/` directory as `*.bats` files, with shared setup in `test/test_helper.bash`.
- Run the whole suite with `bats test/` from the repository root.
- Every behaviour added to a shell script must have a corresponding bats test before committing.
- The suite covers `oneshot`, `loop`, `create-project`, `setup-owner`, and `install-timer`; the same conventions apply to all of them.

## `lib/` Layout (oneshot's function libraries)

`oneshot` is a thin entrypoint: it resolves its own directory, sources every file under `lib/`
in a fixed order, then defines `main()`. All of its actual logic lives in `lib/*` files (no
`.sh` extension, matching `oneshot`/`loop`/`create-project` themselves):

| File | Covers |
| --- | --- |
| `lib/globals` | Config env-var defaults and every `declare -gA` array / mutable counter. **Sourced first** — every other file reads or writes globals declared here, and bash requires an associative array to be `declare -A`'d before any assignment into it. |
| `lib/core` | `die`/`success`/`info`/`warn`/`is_ai_agent`/`hash_sha256`/`check_required_tools`, token loading, config load/validate, disk-space checks. |
| `lib/git` | Repo context (`set_repo_context`) and git plumbing. |
| `lib/github` | Trust/collaborators, the priorities feed, PR/issue discovery and authorship predicates. |
| `lib/github-status` | Pure PR/issue JSON status predicates and Blocked-label application/escalation. |
| `lib/fingerprints` | PR/issue fingerprinting and the CI pending-timeout clock. |
| `lib/state` | Invocation/guard-file counters, rate limiting, blocked/closed-issue markers. |
| `lib/prompts` | CLAUDE.md/prompt building — heredoc bodies the agent reads directly; treat any edit to their wording as a behaviour change, not a refactor. |
| `lib/workflow-board` | GitHub Projects v2 "Workflow" board GraphQL management + its disk cache. |
| `lib/discord` | Discord webhook notifications. |
| `lib/podman` | Container/Podman invocation (`invoke_claude` and everything around it) — the largest, most side-effectful file. |

Add new functions to the right `lib/*` file by what they do, not to `oneshot` itself — `oneshot`
should only ever contain `main()`, its arg parsing, and the source block. When a function
touches more than one concern, put it where its dominant concern lives (e.g. `_build_wf_section`
lives in `lib/prompts` because it emits prompt text, even though it reads Workflow-board state).

`loop`, `create-project`, and `setup-owner` source `lib/core` for the shared output helpers
(`die`/`success`/`info`/`warn`/`is_ai_agent`) rather than keeping their own copies — but only
where the copy was byte-identical. `install-timer`'s `die`/`success`/`info` are a genuinely
simpler variant (no TTY checks) and are deliberately left as local, separate definitions rather
than silently coerced to match; do not "fix" that discrepancy without a considered behaviour
decision. `create-project`'s own `check_required_tools` (a different tool list to `oneshot`'s)
is likewise never deduped — same function name, intentionally different bodies per script.

## Source-Guard Convention

`oneshot`, `loop`, and `create-project` define all of their logic in functions and end with a
source-guard:

```sh
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

This means the script runs `main` only when executed directly. When a test `source`s the
script, the guard is skipped, so all functions become available for unit testing without the
script driving a Claude session or entering the infinite loop. New top-level scripts must
follow the same pattern: factor work into functions and gate execution behind this guard.
The guard stays ONLY in the top-level script (e.g. `oneshot`), never in a `lib/*` file — those
are sourced-only, with no top-level executable code beyond `lib/globals`'s declarations.

Every top-level script resolves its own directory via `${BASH_SOURCE[0]}`, not `$0`: when a test
does `source "${REPO_ROOT}/oneshot"` (or `source_loop`/`source_create_project`/
`source_setup_owner` in `test_helper.bash`), `$0` is the bats runner, not the script itself, so a
`$0`-based `source "${SCRIPT_DIR}/lib/core"` would resolve to the wrong directory and fail under
test. This applies to all four scripts that source a `lib/*` file — `oneshot`, `loop`,
`create-project`, `setup-owner` — including `loop`, even though most of its own tests
(`run_loop_in`) exercise it as a real subprocess rather than sourcing it: `test_helper.bash`'s
`source_loop` still sources it directly for the handful of tests that unit-test `update_scripts`/
`is_ai_agent` in isolation, so `$0`-based resolution silently breaks under that path too — do not
assume a script is exempt just because most of its coverage runs it as a subprocess.

### Fail Loudly When a `lib/*` Source Fails

Every `source "${SCRIPT_DIR}/lib/x"` line must be followed by a dependency-free failure
fallback, e.g. `|| { printf '<script>: FATAL: failed to source %s/lib/x\n' "${SCRIPT_DIR}" >&2;
exit 1; }` — never a bare `source` with no failure check. Without it, a missing/unreadable
`lib/*` file degrades silently: `source` fails but does not stop the script (there is no
`set -e` anywhere in these scripts), so every function the failed file would have defined
(`die`, `info`, `warn`, ...) becomes a plain "command not found" no-op instead of behaving as
expected — an early `... || die "..."` guard that is SUPPOSED to stop the script on a real
failure just silently falls through into the code that follows it instead. Confirmed incident
(#1185 review): a `test/loop.bats` fixture missing `lib/` let a sourced `loop` fall through
`main()`'s `[ -x oneshot ] || die "..."` check into the real `while true` loop, which then ran
real `git switch main` / `git pull` against **the enclosing real repository** every 300 seconds
for hours (see the Test Isolation section below for the other half of why that was possible).
The fallback must not itself call `die` (or any other `lib/core` function) — the whole point is
that it runs when `lib/core` failed to source, so `die` may not exist yet.

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
- `setup_isolated_env` sets `GIT_CEILING_DIRECTORIES="${REPO_ROOT}"`. `make_repo_fixture_dir`
  creates fixtures nested INSIDE this real repo's working tree (`test/.fixture.XXXXXX`), with no
  `.git` of their own — without this guard, a git command run with `-C`/cwd inside such a
  fixture does not fail as intended; git's normal repository-discovery walks up parent
  directories until it finds a `.git`, silently escapes the fixture, and finds THIS repo's real
  `.git`, so the command operates on the real repo instead of erroring "not a git repository"
  (the same #1185 incident referenced above: this is the other half of why a stray real
  `git switch main` reached this actual repo instead of failing inside an isolated fixture).
  `GIT_CEILING_DIRECTORIES` stops git's upward search at (and excluding) `REPO_ROOT`, so any git
  command inside a fixture that lacks its own `.git` fails fast. It does not affect fixtures
  that `git init`/`git clone` their own nested repo (e.g. `setup_local_git_remote`) — git finds
  their own `.git` before ever reaching the ceiling. `make_repo_fixture_dir` also copies `lib/`
  alongside the fixture directory, since any top-level script staged into it now needs to
  source it.

## Mocking External Commands

The scripts call external commands (`curl`, `gh`, `claude`, `git`, `sleep`, and the hashing
tools). Replace these with deterministic, offline stubs using one of two techniques:

- **PATH stub directory** — use `make_stub <name> <body>` from `test_helper.bash`. The stub
  bin directory (`STUB_BIN`) is created inside the repo tree (`test/.stub.XXXXXX`), not under
  the system temp directory, because `/tmp` is mounted `noexec` in sandboxed environments and
  files there cannot be executed as subprocesses. Use this technique for commands invoked as
  subprocesses (`gh`, `git`, `claude`, `curl`, `sleep`). Tests that call `make_stub` must have
  a `teardown()` hook that calls `cleanup_stubs` to remove the stub directory.
- **Function override** — after sourcing the script, redefine a shell function with the same
  name to control its behaviour directly. Use this when you need to inspect arguments or vary
  the response per call.

Stubs must not perform real work: a `sleep` stub returns immediately, a `git` stub is a no-op,
and a `gh`/`curl` stub echoes canned JSON. This keeps the suite fast, deterministic, and free
of side effects.

## Static Analysis

- `shellcheck` must pass for the top-level bash scripts (`shellcheck oneshot loop create-project
  setup-owner install-timer`) and for any `*.bash` test helper. Lint the top-level scripts, not
  the `lib/*` files directly — shellcheck follows a `source` line whose target has a
  `# shellcheck source=lib/x` directive automatically, so checking `oneshot` alone already
  covers every `lib/*` file it sources. Running shellcheck on a `lib/*` file standalone produces
  false-positive SC2034 ("appears unused") warnings for every variable/function it defines but
  never itself uses.
- Each `source "${SCRIPT_DIR}/lib/x"` line needs both a `# shellcheck source=lib/x` directive
  (so shellcheck knows which file it points to) and `disable=SC1091` on the same comment,
  because the path is runtime-computed (`${SCRIPT_DIR}` from `${BASH_SOURCE[0]}`) and shellcheck
  cannot statically resolve it without `-x`/`external-sources=true` — which the pre-commit
  hook's shellcheck invocation does not pass, and `.shellcheckrc` cannot be edited to add it (a
  guardrail hook blocks changes to shared linter config files). Once a file has an unfollowed
  `source`, shellcheck also stops flagging "possible misspelling" (SC2153) for globals assigned
  only in that source — if a *followed* rename ever reintroduces that check, disable SC2153
  file-wide with a one-line comment rather than renaming every local/global pair that collides.
- `checkbashisms` does not apply because the scripts use `#!/bin/bash`.
