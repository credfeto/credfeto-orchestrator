# Development guide

How we work on this repository: what is where, how the shell scripts are written and tested,
how a change goes from an issue to a merged PR, and the GitHub API behaviour that has caught
us out. Start here, then read the guide for the script you are changing.

Back to the [repository README](../../README.md). Contributors who are new to the project
should read [CONTRIBUTING.md](../../CONTRIBUTING.md) first.

## The guides

- General: this page.
- Per script, in [scripts/](scripts/):
  [create-project](scripts/create-project.md),
  [install-claude-hooks](scripts/install-claude-hooks.md),
  [install-timer](scripts/install-timer.md),
  [interactive](scripts/interactive.md),
  [loop](scripts/loop.md),
  [notify-unit-failure](scripts/notify-unit-failure.md),
  [oneshot](scripts/oneshot.md),
  [setup-owner](scripts/setup-owner.md),
  [uninstall-timer](scripts/uninstall-timer.md), and the three scripts baked into the agent image:
  [cfwf](scripts/cfwf.md),
  [pre-commit-check](scripts/pre-commit-check.md),
  [querydb](scripts/querydb.md).
- [The `lib/` function libraries](lib.md).
- [The Claude Code hooks and permission files](claude-hooks.md).

User-level explanations of what the orchestrator does live in the other pages under
[docs/](../): [architecture](../architecture.md), [oneshot](../oneshot.md),
[workflow-board](../workflow-board.md) and [github-integration](../github-integration.md).
The rules the AI agents themselves follow are in [ai/local](../../ai/local/index.md) (this
repository) and [ai/global](../../ai/global/index.md) (shared, maintained in `cs-template`).

Keep these guides true: a PR that changes how a script behaves, is run, or is tested updates
its guide in the same PR. `test/development-guides.bats` fails if a script has no guide or a
link in these pages is broken.

## What is where

| Path | What it is |
| --- | --- |
| `oneshot`, `loop`, `interactive` | The orchestrator itself: one work item per run, the loop that drives it, and the attached interactive session. |
| `create-project`, `setup-owner`, `install-timer`, `uninstall-timer`, `install-claude-hooks`, `notify-unit-failure` | Setup, install and support scripts. |
| `lib/` | The function libraries `oneshot` sources (see [lib.md](lib.md)). |
| `containers/base/` | The agent container image chain and, in `development-full`, the scripts and Claude Code hooks baked into it. |
| `containers/agent/` | The agent image itself: its `Dockerfile` and `entrypoint.sh` (tested by `test/entrypoint.bats`). |
| `tasks/` | Task notes (`healthcheck.md`). |
| `test/` | The bats suites, one per script plus the hook and parity tests, and `test_helper.bash`. |
| `docs/` | User-level documentation and these guides. |
| `ai/local/`, `ai/global/` | Instructions for AI agents working on this repository; local ones are ours, global ones come from `cs-template`. |
| `src/` | Build and packaging props inherited from the template; there is no application code here. |

## Writing the shell scripts

- Scripts are bash (`#!/bin/bash`), run by a shebang line, and have no file extension, except
  `pre-commit-check`, which is POSIX `#! /bin/sh` (so it is also checked with `checkbashisms`).
  They are checked with `shellcheck`, locally by the global pre-commit hooks and in CI; keep
  them clean rather than adding disables, and explain any disable that is unavoidable.
- Only `notify-unit-failure` uses `set -e`. Everywhere else errors are handled where they can
  happen, with an explicit `|| die "message"`, so a failure always says what failed. Quote every
  expansion and prefer `local` variables in functions.
- Every script except `notify-unit-failure`, `pre-commit-check` and `querydb` puts its logic in
  functions and ends with a source guard, so a test can `source` it without running it:

  ```bash
  if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
      main "$@"
  fi
  ```

- Shared helpers live in `lib/` and are only available to scripts that source it. A script that
  is copied on its own into a container image (`cfwf`, `pre-commit-check`, `querydb`) cannot
  source `lib/`, so anything it shares with the orchestrator exists twice and needs a parity test
  that fails when the copies drift. `cfwf`'s Workflow-Status-to-built-in-Status mapping is the
  example: `test/status-mapping-parity.bats`.
- Prefer native `gh <noun> <verb>` subcommands to `gh api graphql`. The exceptions are
  documented where they are made, for example the read-only single-item query in `cfwf`
  (see [cfwf](scripts/cfwf.md)). A GraphQL mutation typed as a command is blocked by the agent
  sandbox (the shared rules in `ai/global/agent-roles.instructions.md` say so; it is the outer
  sandbox, not `claude-settings.json`), and long hand-built `gh` pipelines are the kind of thing
  its command checks reject:
  put a recurring multi-step `gh` pattern behind a script (that is what `cfwf` is) rather than
  asking agents to compose it each time.
- Help text, README text and the guides describe behaviour; when the behaviour changes, change
  all of them and the tests together.

## Testing

- Tests are [bats](https://github.com/bats-core/bats-core) files in `test/`, one per script, all
  loading `test/test_helper.bash`. The framework rules, the source-guard convention and the
  external-command mocking rules are in
  [ai/local/shell-testing.instructions.md](../../ai/local/shell-testing.instructions.md); the
  guide for each script says which helpers and stubs its tests use.
- Every behaviour has a test, written with the change. Tests run offline and in isolation:
  `setup_isolated_env` redirects `HOME`, the XDG directories and the session directory into a
  temporary directory and puts an empty stub directory first on `PATH`; each test then stubs the
  external commands it uses (`gh`, `podman`, `git`, `sleep`, `sudo`) with `make_stub`. A few tests
  use the real `git` against a local `file://` remote, and `GIT_ALLOW_PROTOCOL=file` stops any
  network transport. A test must never reach the network or the real machine.
- Fake `gh` faithfully. The `cfwf` suite uses a `gh` stand-in that applies each call's `--jq`
  filter to a fixture with the real `jq`, so the filters the script hands to `gh` are exercised
  against real-shaped JSON instead of only being recorded.
- Mutation-check every new test: break the code (or the one line the test is about), see the
  test fail, then put the code back. A test that passes on broken code proves nothing, and a
  glue mistake such as a missing space between two arguments is exactly what this catches.
- Run one file with `bats test/<name>.bats`, or a subset of the very large
  `test/oneshot.bats` with `bats -f '<pattern>' test/oneshot.bats`. The whole suite takes
  minutes; CI runs it as `shell-tests`. The global pre-commit hooks (the hooks are not in this
  repository; they come from the developer's global `core.hooksPath`) also run it when a `.bats`
  file is staged, and always under `pre-commit-check`, so such a commit takes minutes.
- Run `git commit` in the background when it will run the suite, and do not edit files while it
  runs: pre-commit stashes unstaged changes for the duration, and an edit made meanwhile can
  make its linters fail. `git push` runs no tests.

## Making a change

1. An issue describes the goal. The plan (files to change, approach, tests, assumptions, open
   questions) is posted on the issue and work starts when it is approved.
2. Work on a branch, never on `main`. Run the pre-commit checks before starting so you know the
   baseline is green.
3. Add a placeholder changelog entry and correct it once there is a real diff. Use
   `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"` to add and
   `dotnet changelog -f CHANGELOG.md -r <Type> -m "<exact message>"` to remove (types: Added,
   Changed, Deprecated, Removed, Fixed, Security, Deployment Changes); never edit `CHANGELOG.md`
   by hand. There is no in-place edit: remove the old entry and add the corrected one.
4. Open a draft PR and keep the Workflow board status in step as the work moves through it.
5. Once CI is green, run the review passes: simplify, code review, security review, and the
   coverage ratchet (skipped when every changed file is a dependency manifest or version pin, a
   workflow, SQL, a shell script, a Dockerfile or documentation). Fix what they find in separate
   commits and re-run each pass until it finds nothing new, its round cap is reached, or its
   convergence rule ends it (see `ai/local/interactive-session.instructions.md`).
6. Mark the PR ready and enable auto-merge; a human reviews before it merges.

The interactive-session rules in
[ai/local/interactive-session.instructions.md](../../ai/local/interactive-session.instructions.md)
give the same lifecycle for a session you drive by hand.

## GitHub API behaviour to allow for

These have all been seen in practice. Where a script has to cope with one, its guide says how.

- **Reads lag writes.** After a write, a read can return the old value for seconds, and a
  listing can leave out a newly added item for minutes. That includes the project board
  (`gh project item-list`), PR lists just after a push, an issue body just after an edit, and
  issue timelines. A read straight after a write therefore cannot tell a lost write from lag.
  The shared rule
  ([GitHub State Lags Behind Writes](../../ai/global/github-cli.instructions.md#github-state-lags-behind-writes-mandatory))
  applies: a write whose call succeeded is done, so do not read it back to confirm
  (`cfwf workflow-status --set` deliberately does not), do not poll or repeat a write because a
  read has not caught up, and treat a read that disagrees with a write just made as lag: carry
  on, check again at a later step, and repeat the write only if the value is still wrong then.
- **`gh project` cannot read one item.** There is no command for a single project item, so
  finding one means listing the whole board. Listing pages at 100 items per request and stops
  at the `-L` limit (30 by default), so a board larger than the limit silently loses items.
  `cfwf workflow-status --check` reads the single item with a read-only GraphQL query instead
  (the one documented use of `gh api graphql` there) and falls back to a listing with a raised
  limit.
- **Writes can be idempotent.** `gh project item-add` for an item already on the board returns
  the existing item, so "add then set" is safe to repeat.
- **The built-in `Status` is not the `Workflow Status`.** Every project has a built-in `Status`
  field (Todo / In Progress / Done) as well as our custom `Workflow Status` (ten options). They
  are separate fields with separate option ids. Both writers set the built-in one to match the
  Workflow Status; see [the workflow-board page](../workflow-board.md).
- **Ids are per project.** Field and option ids are looked up from the board each time (or from
  a cache with a time limit, `PROJECT_CACHE_TTL`, that is cleared only when adding the item to
  the board is rejected), never hard-coded.
- **Project owner is not always the repository owner.** Read the owner from the project's own
  path. Repository names compare case-insensitively.
- **Auth and scopes.** Project reads and writes need the `project` scope on the token. Only the
  orchestrator's project discovery reports a scope, permission or authorisation failure with a
  `gh auth refresh -s project` hint; `cfwf` and the board writes pass `gh`'s error through.

## Adding a script

1. Put it at the repository root (or in `containers/base/development-full/scripts/` if it ships
   in the agent image), executable, with a shebang and no extension.
2. Write `test/<name>.bats` and a `source_<name>` helper if it needs one in
   `test/test_helper.bash`.
3. Write its guide at `docs/development/scripts/<name>.md` in the same shape as the others
   (purpose, running it, how it works, tests, changing it safely, gotchas) and link it from
   the list above.
4. Update the README and any `docs/` page that describes what the scripts do, and add the
   changelog entry.
5. If it ships in the agent image, add it to the `Dockerfile`, its sanity checks, the command
   allowlist and `claude-settings.json` (see [claude-hooks.md](claude-hooks.md)).
