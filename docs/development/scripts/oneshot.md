# oneshot

`oneshot` is the orchestrator's entry point: each run picks at most one work item and drives one fresh, single-phase agent session for it, then exits.

Back to the [development guide](../README.md).

## Purpose

`oneshot` is a script whose logic is one very long `main()` (about 1,400 lines: argument parsing and the per-item decision tree) over the function libraries in `lib/`. A run fetches the priorities feed, walks it in order, and stops after the first item for which it actually invoked the agent. All durable state lives in GitHub (branch, commits, PR comments, labels, Workflow board) plus small files under `ORCHESTRATOR_STATE_DIR`, so every session re-derives its context. For the user-level story read [oneshot.md](../../oneshot.md), [architecture.md](../../architecture.md), [fingerprinting.md](../../fingerprinting.md), [github-integration.md](../../github-integration.md) and [workflow-board.md](../../workflow-board.md); this page is a map for changing the code.

## Running it

- Invocation: `oneshot [--owner <owner>]`. `--owner` is the only option; its value is validated against `^[a-zA-Z0-9][a-zA-Z0-9._-]*$` and any other argument calls `die`. With `--owner`, only items whose repository starts with `<owner>/` are considered, and `validate_config` also requires `tokens/<owner>` (mode 600 or 400).
- Who runs it: the systemd service `install-timer` generates (`ExecStart=<repo>/oneshot --owner <owner>`, 30 seconds by default via `ORCHESTRATOR_TIMER_INTERVAL`, `ORCHESTRATOR_SELF_UPDATE_MANAGED=1`, an `OnFailure=` unit that runs `notify-unit-failure`); `loop` (300 seconds, no `--owner`, refuses to run inside a Claude session); or a person.
- Required tools: `check_required_tools` (lib/core) needs `curl jq podman gh git awk grep flock timeout` and `sha256sum` or `shasum`.
- Configuration comes from `$XDG_CONFIG_HOME/orchestrator/.env`, parsed by `load_env_config` (lib/core) rather than sourced: only a fixed key list is read (Discord webhooks, `GH_TOKEN`, `GH_HOST`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GIT_SIGNING_KEY`, `WHITELISTED_USERS`, `CI_CHECK_TIMEOUT_MINUTES`).
- Environment variables that matter (defaults and validation in `lib/globals`):
  - Paths: `XDG_STATE_HOME` (state, `ORCHESTRATOR_STATE_DIR`), `XDG_PROJECTS_DIR` (clones, `WORK`), `XDG_CONFIG_HOME`.
  - Agent: `ORCHESTRATOR_IMAGE`, `AGENT_TIMEOUT_MINUTES` (default 90), `CLAUDE_CODE_AUTO_COMPACT_WINDOW`.
  - Budgets: `MAX_PR_TOTAL_INVOCATIONS` (computed from the four phase budgets plus 11), `MAX_ISSUE_TOTAL_INVOCATIONS`, `MAX_PR_IDLE_INVOCATIONS`, `MAX_ISSUE_IDLE_INVOCATIONS`, `MAX_CODE_REVIEW_ITERATIONS`, `MAX_SECURITY_REVIEW_ITERATIONS`, `MAX_COVERAGE_ITERATIONS`, `MAX_SIMPLIFY_ITERATIONS`, `SIMPLIFY_THRASH_LIMIT`, `MIN_REVIEW_CONVERGENCE_ROUNDS`, `MAX_PR_ENV_AUTO_UNBLOCKS`, `MAX_CONSECUTIVE_INFRA_FAILURES`, `CI_CHECK_TIMEOUT_MINUTES`.
  - Retries: `GH_USER_`, `PRIORITIES_FETCH_`, `GH_ITEM_FETCH_` and `GH_COLLABORATORS_` `RETRY_ATTEMPTS` and `RETRY_DELAY_SECS` (tests set the delays to 0).
  - Board: `PROJECT_CACHE_TTL` (default 3600 seconds). `ORCHESTRATOR_SELF_UPDATE_MANAGED` enables the stale-checkout refusal.
  - Not overridable from the environment: `PRIORITIES_URL`, `MAX_PROMPT_CHARS`, `FINGERPRINT_SCHEMA_VERSION`, `PRUNE_DANGLING_IMAGES`, `PODMAN_REPLACE_CONTAINER`.
- Exit codes: `die` exits 1. Exit 0 for: another instance holds the lock, low disk space, no items, and every path after the agent ran (`exit 0` at the end of the loop body). Exit 1 when `ORCHESTRATOR_SELF_UPDATE_MANAGED` is set and the checkout is behind `origin/main` (#1298), and when the run scans every item without invoking the agent and at least one item hit a pre-flight container failure (`count_infra_failure`, `return 1` at the end of `main`, #1361); if a later item does run the agent, `main` exits 0 at that point (`oneshot`:~1510).
- Locking: one exclusive `flock` on fd 9 of `ORCHESTRATOR_STATE_DIR/locks/<owner>.lock` (`_global.lock` without `--owner`); see the test "main exits cleanly when another instance holds the lock".

## How it works

Main flow, in `main()` (`oneshot`) unless noted:

1. Source `lib/globals` first, then the other libraries; each `source` has an `|| exit 1` fallback because `die` may not exist yet.
2. Trap `stop_ssh_agent` (lib/podman) and run `migrate_legacy_orchestrator_state` (lib/core), then parse `--owner`.
3. `check_required_tools`, `load_env_config`, the `git_commits_behind` self-update gate (lib/git), `validate_config`, the GPG key check, `preload_ssh_keys` and `setup_cgroup_leaf` (lib/podman), `check_disk_space` (lib/core), then the lock.
4. `fetch_all_priorities` (lib/github) returns only items with status Open or Draft that are not on hold. Return 1 means unreachable (Discord alert), 2 means unparseable.
5. For each item, malformed id, type or repository is skipped with `count_error`. `set_repo_context` (lib/git) sets `OWNER`, `REPO_FULL`, `SESSION_BASE_DIR` and the clone paths.
6. An Issue first goes through `find_open_nonblocked_pr_for_repo ... true` (lib/github). If a bot-driven PR exists the item pivots: `item_id` becomes the PR and `original_issue_id` keeps the Issue. Otherwise `find_any_open_pr_for_repo` (occupied slot, #1476), `fetch_issue_json` (lib/fingerprints), the closed, Blocked, other-assignee and plan-approval checks, the Issue fingerprint comparison, and `find_human_taken_over_pr_for_issue`. A PR listed directly goes through `fetch_pr_json`, the Blocked check, `pr_is_human_driven`, the assignee check and the PR fingerprint comparison.
7. Both PR paths, before comparing fingerprints, defer on pending CI (`pr_json_has_pending_ci_checks`, `ci_checks_timed_out`) and skip a settled PR (`pr_json_is_terminal`, lib/github-status). Idle budgets are applied by `pr_should_advance_unchanged` and `issue_should_advance_unchanged`; exhaustion calls one of the `block_*_for_idle_exhausted_*` functions.
8. The item is picked where control reaches the `# ---- Work block` comment. There `ensure_repo_current` (lib/git; return 2 skips, 1 hands a dirty checkout to the agent), `try_nonagentic_rebase` for BEHIND or DIRTY PRs, `is_owner_rate_limited` (lib/state), `ensure_rules_current`, `find_ai_instructions` and `discover_or_create_workflow_project` (lib/workflow-board) run.
9. The runaway backstops compare `PR_INVOCATION_TOTAL` and `ISSUE_INVOCATION_TOTAL` with their caps and call `apply_blocked_label_with_reason`. `build_issue_prompt`, `build_issue_claude_md`, `build_pr_prompt` and `build_pr_claude_md` (lib/prompts) build the launch prompt and the generated CLAUDE.md.
10. The board is synced before the session (`sync_pr_workflow_status_from_linked_issues`, or `update_workflow_status ... "Not Started"` on an Issue's first touch), then `invoke_claude` (lib/podman) runs the container. Return 2 means the container failed before Claude started.
11. Afterwards the counters are saved (`save_pr_invocation_counts`, `save_issue_invocation_counts`, lib/state), then the fingerprints (`compute_*_fingerprint`, `save_*_fingerprint`) and `save_pr_last_agent_comment_seen`, and `main` exits 0. If nothing was invoked, `notify_discord_no_work` (lib/discord) reports the per-item breakdown built with `record_item_status`.

Library ownership:

| Module | Owns |
| --- | --- |
| `lib/globals` | Env-var defaults and validation, budgets, every `declare -gA` cache; declarations only. |
| `lib/core` | `die`, `info`, `warn`, `success`, config load and validation, tokens, disk space, state migration. |
| `lib/git` | `set_repo_context`, clone and rebase plumbing, `host_to_container_path`, orphaned and stale branch detection. |
| `lib/github` | Priorities feed, trusted logins, PR discovery and human-driven detection, label sync. |
| `lib/github-status` | Pure predicates over PR and Issue JSON, and the Blocked label machinery. |
| `lib/fingerprints` | `fetch_pr_json`, `fetch_issue_json`, fingerprints, the pending-CI clock, last-agent-comment marker. |
| `lib/state` | Invocation, infra and env-unblock counters, forgiveness markers, rate limits, pull-duration history. |
| `lib/workflow-board` | Board discovery and creation, project cache, status reads and writes, ordinal sync. |
| `lib/prompts` | Prompt and CLAUDE.md builders (agent-facing heredocs). |
| `lib/podman` | Container launch, mounts, secrets, GPG and SSH, result handling. |
| `lib/discord` | Webhook notifications with hourly dedup state. |

Where to make a common change:

| To change | Look at |
| --- | --- |
| Whether an item is skipped or stood off | The Issue and PullRequest branches in `main` before the Work block, and the predicate they call (lib/github, lib/github-status). |
| What counts as a settled PR | `pr_json_is_terminal` and `pr_review_pipeline_finished_without_auto_merge` (the board fallback when auto-merge cannot be armed, #1479). |
| What "changed" means | `fingerprint_issue_json` and `fingerprint_pr_json` (bump `FINGERPRINT_SCHEMA_VERSION`, see below). |
| A budget or cap | The `MAX_*` defaults in `lib/globals`, the counters in lib/state, and the backstop blocks in the Work block. |
| Putting an item in Blocked | `apply_blocked_label_with_reason` (verifies the label, comments, notifies Discord, marks for forgiveness). |
| What the agent is told | `build_issue_claude_md` and `build_pr_claude_md`. |
| Container flags, mounts, secrets | `prepare_claude_container_args` and `ensure_agent_container_ready`, both shared with `interactive` via `invoke_claude_interactive`. |
| Workflow Status names or order | `_WF_STATUS_ORDER` (lib/globals); the mapping also exists in `cfwf`, guarded by `test/status-mapping-parity.bats`. |
| A Discord message | The `notify_discord_*` function in lib/discord and [discord-notifications.md](../../discord-notifications.md). |

State files, all named `<Type>_<id>.<suffix>` under `SESSION_BASE_DIR` (`ORCHESTRATOR_STATE_DIR/<owner>/<repo>`) unless noted:

- `.fingerprint`: `<FINGERPRINT_SCHEMA_VERSION>:<sha256>` from `_finalize_fingerprint` (lib/fingerprints).
- `.invocations`: `<total> <idle>` counters; `.infra-failures`: consecutive pre-flight failures.
- `.runaway-blocked`: forgiveness marker, so a human clearing Blocked on a capped item resets its counters.
- `.blocked`: Discord blocked-notifier marker; `.plan-block`: plan self-heal marker; `.background-stall`: the previous session ended in the background-stall pattern (warned about in the next prompt); `.last-diagnostic`: appended to a runaway block reason by `append_last_diagnostic_to_reason`.
- PR only: `.pending_ci` (head SHA and start time for the CI timeout), `.last-agent-comment-seen`, `.env-unblocks`, `.env-unblock-cap-notified`.
- Written by `main` for an Issue: `.closed-pr-tagged` and `.closed-takeover-checked` (one-time closed-issue tagging).
- Not per item: `project-cache.json` (per repo), `rate-limit` and `pull-durations` (per owner, directly under `ORCHESTRATOR_STATE_DIR/<owner>`), and `locks/`.

## Tests

- Everything is in `test/oneshot.bats` (about 16,000 lines, 1,211 `@test` blocks), grouped by `# ---` section comments that name the function or issue. It starts with `bats_require_minimum_version 1.5.0` and `load test_helper`; `setup()` runs `setup_isolated_env` then `source_oneshot`, and `teardown()` runs `cleanup_stubs`.
- `test/test_helper.bash` provides: `setup_isolated_env` (redirects `HOME`, the XDG variables and `SESSION_BASE_DIR` into a temp dir, puts `STUB_BIN` first on `PATH`, sets `GIT_ALLOW_PROTOCOL=file` and `GIT_CEILING_DIRECTORIES`, unsets host variables); `source_oneshot` and `seed_test_repo_context` (context `credfeto/credfeto-orchestrator`); `make_stub` and `make_stub_multiline` (write a temp file, `chmod`, atomic `mv`, `hash -r`); `setup_local_git_remote` and `advance_remote_main` (real git against a local bare remote); `make_repo_fixture_dir`.
- Faking: `gh` is the most stubbed command (`make_stub gh`, a `case "$*"` on the arguments, in the `fetch_single_item_workflow_status` tests for instance); `podman` and `curl` use PATH stubs; `main()` integration tests call `setup_main_mocks` (defined near the "main() skip_repos integration tests" heading, used by about 190 tests) and then override functions such as `fetch_pr_json` and `invoke_claude` with plain function definitions. Some tests use real `git`. Time is faked with `make_stub date "echo 1700000000"`; there is no `sleep` stub here, tests set the `*_RETRY_DELAY_SECS` variables to 0 instead.
- Source guard: `oneshot` ends with `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi` and finds its libraries from `BASH_SOURCE`, so a test can `source` it. See [shell-testing.instructions.md](../../../ai/local/shell-testing.instructions.md).
- Subset: `bats -f '<pattern>' test/oneshot.bats`. Bats still parses the whole file: five tests matched by `fetch_single_item_workflow_status` took about 13 seconds when measured for this guide, so batch your patterns.
- The full suite takes minutes (not timed for this guide; `docs/development/README.md` says the same): more than a thousand tests, each sourcing `oneshot` and eleven libraries in `setup()`, plus tests that run real git. CI runs it as `shell-tests`.

## Changing it safely

1. Put new code in the `lib/` module that owns the concern, not in `oneshot`.
2. `shellcheck oneshot` must be clean; it follows the annotated `source` lines, so it covers `lib/`. Also run `shellcheck test/*.bats` after a test change.
3. Write the test with the change, run the relevant subset, and mutation-check every new test (break the code, watch it fail, restore). Leave the full run to the pre-commit hook.
4. If a hashed field of `fingerprint_issue_json` or `fingerprint_pr_json` is added, removed or changes meaning, bump `FINGERPRINT_SCHEMA_VERSION` by 1 and update the field list in [fingerprinting.instructions.md](../../../ai/local/fingerprinting.instructions.md); see the test "fingerprint_issue_json and fingerprint_pr_json prepend FINGERPRINT_SCHEMA_VERSION".
5. Do not add guidance to `build_issue_prompt` or `build_pr_prompt`; they stay a two-line launch prompt, and rules belong in instruction files ([oneshot-prompts.instructions.md](../../../ai/local/oneshot-prompts.instructions.md)). Editing a `build_*_claude_md` heredoc is a behaviour change. `MAX_PROMPT_CHARS` is only a sanity guard in `invoke_claude`.
6. Update `README.md`, this guide and the affected `docs/` pages, and add the changelog entry with `dotnet changelog`, never by hand.
7. `git commit` and `git push` run the whole suite in the hooks and take minutes: run them in the background and do not edit files meanwhile.

## Gotchas

- `local` inside the `while` loop in `main` only takes effect the first time round, so per-item variables are declared once above the loop and reset at the top of each iteration.
- Dynamic scoping is used on purpose: `require_trusted_logins` sets the caller's `trusted_logins` and `count_error` and reads `item_repo`; `set_pr_has_unaddressed_comment` reads `pr_review_comments` and `pr_issue_comments` and sets `pr_has_unaddressed_comment`. Renaming those locals in `main` breaks the libraries silently, and `SC2034` is disabled at those call sites.
- There is no `set -e` or `pipefail`. Handle each failure explicitly, and remember `die` inside `$(...)` only exits the subshell, so follow it with `|| die` or `|| exit 1`. `SC2153` is disabled file-wide because of the unfollowed `source` lines.
- `prepare_claude_container_args` installs its own `EXIT` trap, which replaces `main`'s; that is why `stop_ssh_agent` is passed in as `extra_exit_cmd`.
- `gh api --paginate` prints arrays back to back: `fetch_pr_review_comments` and `fetch_pr_issue_comments` use `--slurp` and `flatten(1)`. Large JSON goes to `jq` with `--rawfile`, not `--argjson` (argument limit, #1254). `gh --jq` takes one filter string with no `--arg`.
- `gh pr list --author @me` is avoided (broke in gh 2.93.0); `list_bot_created_open_prs` filters on `_GH_ME` client-side.
- Inconsistent default: `CI_CHECK_TIMEOUT_MINUTES` defaults to 1440 in `lib/globals` but an invalid value falls back to 120. The default was raised (240 to 1440, commit 4c71e91) without changing the fallback, and no test pins the fallback, so it looks like an oversight rather than a decision. An invalid value in `.env` is different: `load_env_config` warns and ignores it.
- Caches and invalidation:
  - `_TRUSTED_LOGINS_JSON` resets in `set_repo_context`; `_GH_ME` lasts the process.
  - `_WF_CACHE` and the `_WF_*` globals are in memory; `project-cache.json` expires after `PROJECT_CACHE_TTL`, and `invalidate_project_cache` clears both when `addProjectV2ItemById` is rejected.
  - `_WF_APPROVED_ITEMS` and `_WF_ITEM_STATUS_OPTION_ID` are filled once per repo per run (`_WF_*_FETCHED`) and never refreshed. The fetched flag is set before the walk, so a failed GraphQL page leaves a partial cache for the rest of the run and nothing retries. `fetch_single_item_workflow_status` exists for a fresh read of one item.
  - `ORCHESTRATOR_IMAGE_PULLED_THIS_RUN` limits pulls to one per run.
- GitHub behaviour to allow for (durations are taken from the [development guide](../README.md), not measured here):
  - A read straight after a write can be stale. Handled: `apply_blocked_label` verifies the label after writing and retries once (#1092); before honouring a budget reset, `item_confirmed_not_blocked_live` re-reads the label (#1310, test "main does not reset or invoke the agent for a PR when a stale read-after-write lags..."); PR pending-CI and terminal checks run whatever the fingerprint says (#1256) and a session that ends with CI still pending is not charged as idle (seen on PR #1473). Not handled: board writes are never read back, and a stale `fetch_single_item_workflow_status` after a session looks like "no progress", so the tick is charged to the idle budget.
  - Commit-author login resolution lags a push: `json_has_commit_author_identity` falls back to the raw email for the bot's own identity only (#1294). For other trusted humans a lagging login is not handled (the NOTE in `pr_is_human_driven`).
  - `gh project` has no single-item read. `oneshot` never calls `gh project`; it reads the board with `gh api graphql` `items(first:100)` and follows `hasNextPage`, so it is not capped by `-L`. Its single-item read (`fetch_single_item_workflow_status`) resolves the item id with `addProjectV2ItemById`, a mutation that is idempotent for an item already on the board (and adds the item if it was missing). `fields(first:30)` and `fieldValues(first:50)` are fixed caps with no pagination.
  - `gh pr list` and `gh issue list` cap at `--limit`: PR discovery uses 200 (raised from 30, #1134), so a repository with more open PRs is silently truncated and nothing detects it; `report_missing_workflow_project` and `report_unparseable_rate_limit` use 100 with a title search.
  - List endpoints can lag a new PR. `find_any_open_pr_for_repo` and `resolve_resumable_issue_branch` (`gh pr list --head`) have no guard beyond failing closed on an error (a failed count is treated as one open PR) and the next tick.
  - Issue timelines: `oneshot` never reads them; only [debugging.instructions.md](../../../ai/local/debugging.instructions.md) tells a human to.
