# The lib/ function libraries

The eleven sourced-only files in `lib/` hold all the logic that `oneshot` and `interactive` run (both source all eleven); `loop`, `create-project` and `setup-owner` source only `lib/core`.

Back to the [development guide](README.md).

## How the libraries are loaded

`oneshot` resolves its own directory from `${BASH_SOURCE[0]}` (never `$0`, which is the bats runner when a test sources it) and sources the libraries in this fixed order: `globals`, `core`, `git`, `github`, `github-status`, `fingerprints`, `state`, `prompts`, `workflow-board`, `discord`, `podman`. Each `source` line carries a `# shellcheck source=lib/x disable=SC1091` directive and a dependency-free failure fallback that prints `FATAL: failed to source` and exits 1. The fallback cannot call `die`, because `die` lives in `lib/core` and may not have loaded.

Only `lib/globals` has to come first: it declares every associative array (bash needs `declare -A` before any assignment into one) and the configuration defaults. The other libraries call each other by function name at run time, so the order does not encode the dependencies below, and there are cycles (`github-status` calls `discord`, which calls `github-status`). The dependency lists are the calls to functions defined in another library, found by scanning for function names, so a call built dynamically would not show up.

The `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi` source guard lives only in the top-level script. A `lib/` file starts with `# shellcheck shell=bash` and has no shebang and no guard. See [shell-testing.instructions.md](../../ai/local/shell-testing.instructions.md) for the reasoning and the shellcheck rules.

## The modules

### globals

Configuration and state declarations, and nothing else. Environment-backed defaults (`AGENT_TIMEOUT_MINUTES`, `MAX_PR_TOTAL_INVOCATIONS`, `CI_CHECK_TIMEOUT_MINUTES`, `PROJECT_CACHE_TTL`, the `GH_*_RETRY_ATTEMPTS` family), the schema counter `FINGERPRINT_SCHEMA_VERSION`, the per-item counters (`PR_INVOCATION_TOTAL`, `ISSUE_INVOCATION_IDLE`), and the Workflow board arrays (`_WF_OPTION_IDS`, `_WF_BUILTIN_OPTION_IDS`, `_WF_CACHE`, `_WF_APPROVED_ITEMS`, `_WF_ITEM_STATUS_OPTION_ID`, `_WF_STATUS_ORDER`). Most numeric overrides are checked with a regex and fall back to the default (`CI_CHECK_TIMEOUT_MINUTES` falls back to 120 rather than its default of 1440, and `PROJECT_CACHE_TTL` is not validated). Depends on: nothing.

### core

`die`, `success`, `info`, `warn`, `is_ai_agent`, `require_tools`, `check_required_tools`, `hash_sha256`, token loading (`read_token_if_safe`, `load_token_for_owner`, token files must be mode 600 or 400), `load_env_config` and `validate_config`, `check_disk_space`, and the first-run set-up of `$XDG_CONFIG_HOME/orchestrator` (`bootstrap_orchestrator_config`, `migrate_legacy_orchestrator_state`). Depends on: nothing. Most other libraries use it.

### git

`set_repo_context` sets `OWNER`, `REPO`, `REPO_FULL`, `RULES_DIR`, `REPO_WORK_DIR`, `SESSION_BASE_DIR`, `CLAUDE_STATE_DIR` and `ORCHESTRATOR_CACHE_DIR`, and clears `_TRUSTED_LOGINS_JSON`. Also `host_to_container_path`, checkout upkeep (`ensure_repo_current`, `ensure_rules_current`, `try_nonagentic_rebase`, `recover_orphaned_branch`), issue branch lookup (`issue_branch_regex`, `find_stale_issue_branch`), and the checkout resolution `interactive` uses (`resolve_repo_dir`, `resolve_repo_full`). Depends on: `core`.

### github

Trust and discovery. `get_trusted_logins` (cached in `_TRUSTED_LOGINS_JSON`), `fetch_all_priorities` (the priorities feed, not GitHub), `resolve_gh_me` (cached in `_GH_ME`), `list_bot_created_open_prs`, `find_open_nonblocked_pr_for_repo`, `fetch_pr_fields_json`, and the human-takeover predicates (`pr_has_bot_authored_commit`, `find_human_taken_over_pr_for_issue`, `pr_is_human_driven`). Depends on: `core`, `git`.

### github-status

Pure predicates over already-fetched JSON (`pr_json_is_terminal`, `pr_json_has_pending_ci_checks`, `pr_json_has_failed_required_check`, `issue_json_has_blocked_label`) and the Blocked-label machinery built on them (`apply_blocked_label`, `apply_blocked_label_with_reason`, the `block_pr_for_*` and `block_issue_for_*` escalations). Depends on: `core`, `discord`, `fingerprints`, `prompts`, `state`.

### fingerprints

The "did this item change" state. `fetch_pr_json`, `fetch_issue_json`, `fingerprint_pr_json`, `fingerprint_issue_json`, `compute_*_fingerprint`, `save_*` and `load_*` for the `<Type>_<id>.fingerprint` files under `SESSION_BASE_DIR`, and the CI pending clock (`ci_checks_timed_out`, `clear_pr_ci_pending_state`, using `CI_CHECK_TIMEOUT_MINUTES`). See [the fingerprinting page](../fingerprinting.md). Depends on: `core`, `github`, `github-status`, `workflow-board` (plan approval is hashed via `issue_plan_approved`).

### state

File-backed bookkeeping between ticks. Invocation guard files (`load_pr_invocation_counts`, `save_issue_invocation_counts`, the `MAX_*_INVOCATIONS` backstops), environment-block auto-unblocking (`try_auto_unblock_env_diagnosed_pr`), rate limiting (`save_rate_limit`, `is_owner_rate_limited`, `parse_reset_time`), pull-duration history, and the `.blocked`, plan-block, background-stall and last-diagnostic markers. Depends on: `core`, `github-status`, `podman`.

### prompts

Builds the CLAUDE.md and launch prompts (`build_issue_claude_md`, `build_pr_claude_md`, `build_interactive_claude_md`, `_build_wf_section`). The heredoc bodies are read by the agent, so a wording change is a behaviour change. `_build_wf_section` reads the `_WF_*` globals directly. Depends on: `github-status` (`human_plan_approval_jq_literal`).

### workflow-board

The GitHub Projects v2 "Workflow" board. Discovery and creation (`discover_or_create_workflow_project`), the disk cache (`load_project_cache`, `save_project_cache`, `invalidate_project_cache`), writes (`update_workflow_status`, `_wf_set_builtin_status`), reads (`fetch_board_item_statuses`, `fetch_board_approved_items`, `fetch_single_item_workflow_status`, `board_substatus_for_item`), the forward-only PR mirror (`sync_pr_workflow_status_from_linked_issues`), and the status mappings (`coarse_status_for_substatus`, `builtin_status_for_workflow_status`, `priority_for_labels`). Depends on: `core`, `github`.

The option maps (`_WF_OPTION_IDS`, `_WF_BUILTIN_OPTION_IDS`) are copied between the live globals, the in-memory `_WF_CACHE` and the on-disk cache by helpers written once, which take the array by name (a nameref): `_wf_reset_assoc`, `_wf_assoc_to_json`, `_wf_assoc_from_json`, `_wf_cache_store_assoc`, `_wf_cache_load_assoc` and `_wf_cache_forget_assoc`. `update_workflow_status` writes a field through `_wf_set_item_field` (Workflow Status first, then `_wf_set_builtin_status` for the built-in Status, which uses the same helper).

### discord

Webhook notifications (`notify_discord_work_item`, `notify_discord_blocked_item`, `notify_discord_no_work` and the rest), the URL builder `build_item_url`, and per-owner dedup files (`_discord_dedup_allowed`). Depends on: `core`, `github-status`, `state`, `workflow-board`.

### podman

Launching the agent container. `invoke_claude` and `invoke_claude_interactive` share `ensure_agent_container_ready` and `prepare_claude_container_args`. Also `run_claude_fresh`, cgroup, SSH and GPG set-up, `validate_bind_mounts` and `current_agent_image_sha`. Depends on: `core`, `discord`, `state`.

`lib/discord` and `lib/podman` each declare a few plain top-level variables of their own (`DISCORD_RESOLVED_WEBHOOK_URL`, and `CLAUDE_MD_TMPFILE`, `CLAUDE_PROMPT`, `GPG_PUBKEY_TMPDIR`, `PODMAN_SECRET_NAME`, `GH_ENTERPRISE_SECRET_NAME`, `CLAUDE_SCRATCH_TMPDIR`). They are invocation-scoped scratch values assigned to `""`, so they are an existing exception to the "globals live in `lib/globals`" rule below rather than a pattern to copy.

## Adding to a module

- Put a function in the library whose concern dominates it, not in `oneshot`, which should only hold `main()`, argument parsing and the source block. When it spans concerns, use its main concern (`_build_wf_section` is in `prompts` because it emits prompt text, although it reads board state).
- A new global, default or counter goes in `lib/globals`, and an associative array must be declared there with `declare -gA`. Do not add another top-level variable in a library.
- Sourcing a library must have no side effects: no function calls, no I/O, no `gh`, `git` or network calls. Only function definitions (and, in `globals`, declarations and default computation).
- A new library file needs a source line in `oneshot` with the shellcheck directive and the `|| { printf ...; exit 1; }` fallback. Lint with `shellcheck oneshot loop create-project setup-owner install-timer interactive`, not the `lib/` file alone, which gives false SC2034 warnings; also run `shellcheck test/*.bats` when you add or change a test. `oneshot` also carries a comment block listing which functions are declared in which library; keep it in step.
- Unit-test every function by sourcing `oneshot` in a bats test: `load test_helper`, then `setup_isolated_env` and `source_oneshot` in `setup()`, and `cleanup_stubs` in `teardown()`. `source_oneshot` sources `oneshot` (the guard skips `main`) and `seed_test_repo_context` sets the repo context to `credfeto/credfeto-orchestrator` with state directories inside the test's temporary directory. Stub `gh`, `git`, `curl` and `sleep` with `make_stub`, or redefine the function after sourcing. Most of these tests are in `test/oneshot.bats`; run a subset with `bats -f '<pattern>' test/oneshot.bats`.
- Mutation-check each new test: break the line the test is about, watch it fail, restore it. See the [development guide](README.md).
- If you add, remove or change what `fingerprint_issue_json` or `fingerprint_pr_json` hash, bump `FINGERPRINT_SCHEMA_VERSION` (currently 2) by exactly 1 in the same change, and update the field list in [fingerprinting.instructions.md](../../ai/local/fingerprinting.instructions.md). The two functions share one counter. No test checks that you did; reviewers must.
- `cfwf` is copied alone into a container image and cannot source `lib/`. Anything it shares with the libraries is written twice and needs a parity test. The built-in Status mapping is the current case: `builtin_status_for` in `cfwf` and `builtin_status_for_workflow_status` in `lib/workflow-board`, held together by `test/status-mapping-parity.bats`. A similar test, `test/entrypoint-cache-path-parity.bats`, pins the cache path the `cache-gh-lookups` hook shares with `entrypoint.sh`.

## GitHub API behaviour

The library code has to allow for the following. Where the code does nothing about one, that is said.

### Reads that lag behind writes

A list, a search or a field value can return the old state for seconds to minutes after a write.

- `update_workflow_status` never reads its write back. It trusts the exit status of `gh api graphql`, warns on failure and returns 0 either way. Nothing reads the built-in Status back at all.
- `apply_blocked_label` writes the label, then makes a live `--json labels` read, retries once (creating the `Blocked` label first) and warns on failure. There is no delay between the write and the read, so a read that lags looks the same as a lost write and can end in a "Failed to verify" warning although the label landed.
- `item_confirmed_not_blocked_live` (#1310) is the guard for a stale "not blocked" reading: a runaway marker is only cleared when a fresh direct read positively says the item is not `Blocked`, and an empty or failed read counts as still blocked.
- `json_has_commit_author_identity` (#1294) copes with a commit author login that has not resolved yet, by accepting the bot's own `GIT_USER_EMAIL` when no author of that commit has a login. `pr_is_human_driven` still matches other trusted humans by resolved login only, so a lagging login for a human is not covered (a comment in `lib/github` says so).
- `fetch_single_item_workflow_status` reads one item fresh but does not wait or retry, so a read straight after `update_workflow_status` can return the old value. It also calls `addProjectV2ItemById` to find the item id, so asking about an item that is not on the board adds it.
- `sync_pr_workflow_status_from_linked_issues` and `sync_pr_labels_from_linked_issues` treat a failed or empty `closingIssuesReferences` read as "no linked issue". Nothing distinguishes that from a lagging read; the status mirror is forward-only and runs every tick, so a wrong first-touch value is corrected on a later tick.
- `resolve_resumable_issue_branch` and `find_any_open_pr_for_repo` read `gh pr list`. Nothing re-checks a list that has not yet shown a just-opened PR. On a failed count `resolve_resumable_issue_branch` assumes a PR exists and does not resume.

### The board has no single-item read

`gh project` has no command that reads one item, and `lib/` does not use `gh project` at all. It uses `gh api graphql` instead. `fetch_board_item_statuses` and `fetch_board_approved_items` walk the whole board with `items(first:100)` and a cursor, once per repo per process. `fetch_single_item_workflow_status` is the one-item alternative. The queries also fix `fieldValues(first:50)` (items) and `fields(first:30)` (project) with no paging, so more than that is silently not seen. A failed page warns and stops the walk, but the "already fetched" flag was set before it started, so the partial result stands for the rest of the process. `cfwf --check` also reads the single item with `gh api graphql`, but falls back to `gh project item-list` with a raised limit, and its writes use native `gh project` commands.

### Capped list commands

`gh pr list --limit 200` (`list_bot_created_open_prs`, `find_any_open_pr_for_repo`) and `gh issue list --limit 100` (the rate-limit and Workflow-setup issue lookups) return at most that many items. The comment in `lib/github` records that the default is 30, and that a truncated list made the bot's own PR invisible (#1134). The code never checks whether the cap was reached, so a repo beyond it is truncated without a warning. Comment, collaborator and inline-comment reads use `gh api --paginate` with no cap. `fetch_pr_json` uses `gh pr view --json`; the code does nothing to detect a truncated list there.

### Caches and their invalidation

- `_TRUSTED_LOGINS_JSON` is per repo and cleared by `set_repo_context`. `_GH_ME` lasts for the process.
- `_WF_CACHE` (with `_WF_PROJECT_ID`, `_WF_STATUS_FIELD_ID`, `_WF_OPTION_IDS` and the built-in equivalents) is in memory, keyed by `REPO_FULL` and lost at exit. `discover_or_create_workflow_project` checks it first.
- The disk cache is `${SESSION_BASE_DIR}/project-cache.json`, valid for `PROJECT_CACHE_TTL` seconds (default 3600). A missing, unparseable, stale, other-repo or incomplete entry is a miss. Writing it is best effort (warn only).
- `invalidate_project_cache` deletes the file and clears the repo's `_WF_CACHE` keys and live globals. It is called from exactly one place: when `addProjectV2ItemById` fails in `update_workflow_status` (a deleted or recreated project). A failed field write, a failed board read or a renamed option does not invalidate anything; the stale ids stay until the TTL runs out.
- `_WF_ITEM_STATUS_OPTION_ID` and `_WF_APPROVED_ITEMS` are filled once per repo per process and never invalidated, and `update_workflow_status` does not update them. Within one process `board_substatus_for_item` and `issue_plan_approved` therefore report the state before that process's own writes, or "Unknown" for an item added after the fetch.

### The built-in Status field (#1493)

`update_workflow_status` adds the item to the board, sets the Workflow Status, and only if that succeeds calls `_wf_set_builtin_status`. That maps the status with `builtin_status_for_workflow_status` (Todo for Not Started and Planning, In Progress for Approved through Human Review, Done for Complete) and looks the option up in `_WF_BUILTIN_OPTION_IDS`, whose keys are lower-cased names. A project with no `Status` field, a renamed or removed option, or a failed mutation gets a warning and the Workflow Status stands.

Discovery reads the field named `Status` from the same fields query and records `_WF_BUILTIN_FIELD_ID` and the option ids in the `builtin_*` keys of `_WF_CACHE` and in the disk cache. `load_project_cache` treats an entry without `builtin_field_id` as a miss (#1493), so caches written before #1493 are rediscovered once. Reading the code, the same rule means a project that has no built-in `Status` field at all never gets a disk cache hit and is rediscovered on every run; nothing in the code or tests states whether that is intended.
