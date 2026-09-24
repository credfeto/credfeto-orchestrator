# cfwf

A bash helper (Credfeto WorkFlow) that gives each recurring multi-step `gh` pattern one flat command: move an item on the Workflow board, read its status, or list the labels of the issues a PR closes.

Back to the [development guide](../README.md).

## Purpose

Agents used to re-derive the same multi-statement `gh` scripts every session. `cfwf` replaces them with single commands, so one `command-allowlist` entry and one `Bash(cfwf *)` permission cover them. It has three commands:

- `workflow-status --set` puts an issue or PR on the Workflow board and sets its Workflow Status and the project's built-in Status.
- `workflow-status --check` prints where an item currently is.
- `closing-issue-labels` prints the labels of the issues a PR closes.

The board, its Workflow Status field and the option ids are all looked up from `--repo` and `--status`, so callers never handle project, field or option ids. The board itself is described in `docs/workflow-board.md`.

## Running it

```bash
cfwf workflow-status --set   --repo <owner/repo> (--pr <n> | --issue <n>) --status <name>
cfwf workflow-status --check --repo <owner/repo> (--pr <n> | --issue <n>)
cfwf closing-issue-labels    --repo <owner/repo> --pr <n>
cfwf help [command]
```

Options, all validated before `gh` is called (test "--set rejects values that could alter a jq filter or a URL, without calling gh"):

- `--repo` must match `owner/repo` (`A-Za-z0-9_.-` on each side).
- `--pr` and `--issue` are digits only and mutually exclusive; one is required for both `--set` and `--check`.
- `--status` is any text without control characters. It is matched, without regard to case, against the display names of the board's Workflow Status options, never put into a filter. `--set` needs it; `--check` rejects it (`--status is only valid with --set`).
- `--set` and `--check` are mutually exclusive. `-h`/`--help` prints the usage of the current command and exits 0 without calling `gh`.
- The old id options (`--owner`, `--project-number`, `--project-id`, `--field-id`, `--option-id`, `--url`) no longer exist and are rejected as unknown (test "the board ids and the URL are not options any more").
- `closing-issue-labels` accepts only `--repo` and `--pr` (`closing-issue-labels takes only --repo and --pr`).

Environment variables: `cfwf` defines none. `gh` reads its own (for example `GH_TOKEN`), and `mktemp` honours `TMPDIR`. `CFWF_BIN_DIR` belongs to `install-claude-hooks`, not to `cfwf`.

Output and exit codes:

- `--set` prints `Set <url> to <status>` (the canonical option name, so `ai security review` prints `AI Security Review`) and exits 0. The URL is `https://github.com/<repo>/pull/<n>` or `.../issues/<n>`.
- `--check` prints one line, `<Workflow Status> (<built-in Status>)`, for example `Development (In Progress)`. `(unset)` stands for a Workflow Status the item does not have and `unset` inside the brackets for a missing built-in Status. It exits 1 with `<repo>#<n> is not on project <number>` when the item is not on the board.
- `closing-issue-labels` prints the sorted, de-duplicated labels, one per line, leaving out exactly `Blocked` and `On-Hold` (`Blocked-by-upstream` is kept).
- Exit 0 is success and help; 1 is a runtime failure (`die`, prefixed `cfwf:`); 2 is a usage error, printed with the usage text on stderr. A bare `cfwf` prints the usage to stderr and exits 2.

## How it works

`workflow-status --set` (`workflow_status_set`):

1. `require` and `require_target` check the options (`--pr` becomes type `PullRequest`, URL kind `pull`; `--issue` becomes `Issue`, `issues`), and `require_gh` checks `gh` is installed.
2. `resolve_project` runs `gh repo view <repo> --json projectsV2` and keeps the one open project titled `Workflow` (a closed one is ignored; none or two is a `die`). The owner is taken from the project's own `resourcePath` (`/users/...` or `/orgs/...`), not assumed to be the repository owner.
3. `resolve_status` runs `gh project field-list <n> --owner <owner> -L 100`, finds the `Workflow Status` field and the option named `--status`, and rewrites `STATUS` to that option's canonical name. An unknown name dies listing the valid ones. `Status` options are collected too; `builtin_status_for` maps the Workflow Status to Todo, In Progress or Done, and if the project has no such option it warns on stderr and skips that write.
4. `gh project item-add ... --format json --jq .id` adds the item (the help text says adding is idempotent), and the id is checked against `^[A-Za-z0-9_=-]+$` before use.
5. `gh project item-edit` sets the Workflow Status, then a second `item-edit` sets the built-in Status. There is no read-back and no other `gh` call after that: the script prints `Set <url> to <status>`.

`workflow-status --check` (`workflow_status_check`) calls `resolve_project` and then `read_target_status`:

1. `graphql_query` runs `gh api graphql` with a read-only query for the one issue (`issue(number:)`) or pull request (`pullRequest(number:)`), asking for `projectItems(first:100)` with `fieldValueByName(name:"Workflow Status")` and `builtin:fieldValueByName(name:"Status")`. The `--jq` filter keeps only the item whose `project.id` is the Workflow project's. stdout goes to `GRAPHQL_OUTPUT` and stderr to a temp file read into `GRAPHQL_ERROR`, so gh's stderr chatter can never end up in a value.
2. If GitHub answers `Could not resolve to an Issue with the number` (or `... a PullRequest ...`) that means not found, not failure.
3. Any other failure calls `fall_back_to_listing`: a warning on stderr (`graphql_failure_text` quotes the first line only, printable characters only, at most 200 characters) and then `gh project item-list <n> --owner <owner> --format json -L 10000` (`ITEM_LIMIT`), filtered by repository (case-insensitive), number and type.
4. If both fail, `cfwf` dies with `both the direct query and the listing of project <n> failed`.

`closing-issue-labels` (`cmd_closing_issue_labels`) reads `gh pr view --json closingIssuesReferences`, then `gh issue view <n> --repo <that issue's own repo> --json labels` for each (a PR can close an issue in another repository), filters out `Blocked` and `On-Hold`, and runs `sort -u`. An unreadable issue or a malformed reference produces a warning, still prints the other labels, and makes the exit status 1, so a partial list is never mistaken for a complete one.

External tools: `bash` 4+ (associative arrays and `${var,,}`; it is not POSIX sh), `gh` (authenticated), `mktemp`, `grep` and `sort`. The script runs `main` only when executed (`BASH_SOURCE[0] = $0`), so `test/status-mapping-parity.bats` can `source` it to reach `builtin_status_for`.

Shipping: the Dockerfile copies it to `/usr/local/bin/cfwf` (root:root, 0755) and checks presence and the executable bit. It is on `claude-hooks/command-allowlist` and `Bash(cfwf *)` is in `claude-settings.json`, kept in step by `test/command-allowlist-parity.bats`. On a host, `install-claude-hooks` runs `install_cfwf`: `install -m 0755` into `${CFWF_BIN_DIR:-/usr/local/bin}`, retried under `sudo` as root:root if that fails, and otherwise it prints the exact command to run. It is a copy, not a symlink, so re-run the installer after changing `cfwf`. The installer refuses to run inside a Claude Code session. Tests: `test/install-claude-hooks.bats` ("main installs cfwf into the shared bin directory, executable by everyone", "re-running main replaces an older installed cfwf", the sudo tests and "dies when the source cfwf script is missing").

### Why it is built this way

GitHub's project API lags behind writes, and `gh project` has no command that reads a single item. Those facts drive every design decision (issue #1491; the `--set` and `--check` help text and the comments in the script say the same):

- No read-back after `--set`. A read straight after a write cannot tell a lost write from lag: `gh project item-list` can leave out a newly added item for minutes, and a change to an existing item can take seconds to show even on a direct read. An earlier version read the value back and reported a false "did not persist" for writes that had persisted. Now `--set` trusts `gh project item-edit`'s exit status and prints `Set <url> to <status>`; to confirm, run `--check` after allowing for the lag.
- `--check` reads one item directly. `gh project item-list` is a listing of the whole board: it is paged, capped (`-L`), can be slow, and is slow to show a new item. A single-item GraphQL query avoids the paging and the cap. This is the only `gh api graphql` use in `cfwf` and the query contains no mutation (test "no gh api graphql call ever carries a mutation"); every write is a native `gh project` command.
- A fallback to listing exists, with a visible warning, so a GraphQL failure does not make `--check` useless. The listing asks for 10000 items (`ITEM_LIMIT`) rather than accept a default page; the field listing asks for 100 (`FIELD_LIMIT`, test "--set reads the project's fields with a limit above the default page size of 30").
- The built-in Status mapping is duplicated. `cfwf` is copied alone into the image and cannot source `lib/`, so `builtin_status_for` mirrors `coarse_status_for_substatus` in `lib/workflow-board` (via `builtin_status_for_workflow_status`). `test/status-mapping-parity.bats` is the only thing stopping them drifting apart.

## Tests

`test/cfwf.bats` covers help and usage, `--set`, `--check` and `closing-issue-labels`. `test/status-mapping-parity.bats` sources `cfwf` in a subshell and compares `builtin_status_for` with `builtin_status_for_workflow_status` from `lib/workflow-board` for every name in `_WF_STATUS_ORDER`, and checks both give nothing for an unknown or empty name and that the mapping is Todo, In Progress and Done as documented.

How `gh` is faked: `setup` builds a `gh` PATH stub with `make_stub_multiline gh`. The stub logs every call's arguments to `GH_LOG`, then routes on the first two words (`repo view`, `project field-list`, `project item-add`, `project item-edit`, `project item-list`, `api graphql`, `pr view`, `issue view`). For every call except `project item-edit` (which only succeeds or fails) it applies the call's own `--jq` filter to a fixture file in `GH_FIXTURES` (`issue-view-<n>.json` for `issue view`), using the real `jq`, so the filters `cfwf` sends are run against real-shaped JSON and not merely recorded. Any other call exits 99 with `gh stub: unexpected call`.

- Failure switches are marker files in `GH_FIXTURES`: `repo-view.fail`, `item-add.fail`, `item-edit.fail`, `item-edit.failfield` (fails only the edit for the field id it contains), `item-list.fail`, `graphql.fail` (stderr text and exit 1), `graphql.failout` (stdout text and exit 1) and `graphql.stderr` (stderr noise on success).
- Fixture helpers: `write_repo_view`, `write_item_list`, `write_full_field_list`, `write_graphql_target`, `write_pr_view`, `use_fallback` (makes every `api graphql` call fail), `set_args`, `gh_call_count` and `gh_line_of` (line order in `GH_LOG`).
- The stub needs the real `jq` on the test host (`cfwf` itself never calls `jq`; it hands filters to `gh --jq`).
- `setup_isolated_env` and `cleanup_stubs` come from `test/test_helper.bash`; tests use `run --separate-stderr` when they need stderr on its own.

Run just these files:

```bash
bats test/cfwf.bats
bats test/status-mapping-parity.bats
bats test/install-claude-hooks.bats
```

## Changing it safely

- Run `shellcheck containers/base/development-full/scripts/cfwf` and keep it clean.
- Run `bats test/cfwf.bats`, and `bats test/status-mapping-parity.bats` if the status mapping or the sourcing guard changed.
- Mutation-check any new test: break the code (for example swap `pullRequest` and `issue`, drop the `project.id` filter, or add a read-back after `--set`) and confirm the test fails, then restore it.
- Update the help text (`usage_workflow_status`, `usage_general`, `usage_closing_issue_labels`) and the test that pins it ("the workflow-status help states that --set does not read back, ...").
- Update `containers/base/development-full/README.md` (the `cfwf` bullet), `docs/workflow-board.md` (built-in Status section) and the `Dockerfile` comment when the surface changes. If the name or install path changes, also update `command-allowlist`, `claude-settings.json` and `install-claude-hooks`, then run `test/command-allowlist-parity.bats` and `test/install-claude-hooks.bats`.
- A new Workflow Status needs both mappings changed (`builtin_status_for` in `cfwf`, `coarse_status_for_substatus` in `lib/workflow-board`) and `_WF_STATUS_ORDER`; the "ten Workflow Statuses" parity test will fail until the count is updated on purpose.
- Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- The pre-commit hooks run the whole bats suite, so commits and pushes take minutes. Run them in the background.

## Gotchas

GitHub API behaviour `cfwf` has to allow for, and what it does:

- Lagging reads after a write. `--check` straight after `--set` may still show the old value, even from the direct query. `--set` therefore never verifies, and callers who must confirm should retry `--check` after a delay. `--check` itself does not retry.
- Listing omits new items. Only the fallback path lists the board, so the fallback can report `is not on project` for an item that was just added. The direct query does not depend on the listing.
- Listing paging and cap. The fallback reads at most 10000 items (`ITEM_LIMIT`), so on a bigger board it can miss an item. The direct query is not capped in this way. Field lists ask for 100 (`FIELD_LIMIT`).
- No single-item read in `gh project`. That is why `--check` uses GraphQL; `projectItems(first:100)` in that query is itself a limit on how many projects one issue can be on.
- `gh` may print to stderr even on success (test "anything gh writes to stderr on a successful read never ends up in the value"), and with `--jq` it can put an error body on stdout, which is why `graphql_failure_text` falls back to stdout.
- The test stub does not run the GraphQL query text on a server, so a wrong field name in the query would not be caught by the tests. The tests assert on the logged query text and the filter only.

Other things that bite:

- `--issue` with a pull request number (or the reverse) is "not on project", not an error, because `issue(number:)` resolves only issues and `pullRequest(number:)` only PRs.
- `--set` is not atomic. If the Workflow Status write succeeds and the built-in Status write fails, it exits 1 with `set the Workflow Status of <url> but could not set its built-in Status to <status>` and the first write stays.
- `--status` is matched only against Workflow Status options, so `--status Todo` is `unknown status`.
- Two open projects titled `Workflow` linked to a repository make `cfwf` refuse to guess. Close the old one.
- The item-listing JSON key used by the fallback is `"workflow Status"` (with a lower-case `w`) as `gh` emits it; if `gh` changes the key, the fallback will report `(unset)`.
- Unknown options exit 2 before any `gh` call, so a typo never reaches `gh`; options after `--help` are never looked at.
