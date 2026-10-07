# Issue 1581: Implementation Plan (temporary copy)

This is a temporary copy of the Implementation Plan for #1581. It is committed to the repository because GitHub was returning 500 errors on comment writes on 2026-10-07, so the plan could not be posted to the issue.

Once GitHub writes work again, this plan will be posted to #1581 and this file deleted.

The owner signed off this plan in live chat on 2026-10-07:

> but approved for now

## Implementation Plan

Revision of the earlier plan on this issue. It includes the owner's live-chat answers to Q1-Q5: Q1 and Q2 are recorded in the comments above, and Q3-Q5 are quoted here. Q3's final answer:

> 3 yes they look good to me

Q4's answer, quoted:

> 4 yes we should add them as new convention from now on

Q5 (agents in other repos never see this repo's local rules, so should the global cs-template skill carry the `tool(cfwf):` prefix?), answered in live chat:

> q5 yes

### Files to change

- Issue titles (no file): all open issues in `credfeto/credfeto-orchestrator`, renamed per the table below with `gh issue edit <n> --repo credfeto/credfeto-orchestrator --title "<new>"`. No labels, bodies or board fields are touched.
- `ai/local/issue-titles.instructions.md` (new): the title convention as a standing rule for every issue raised on this repo. It covers the format, the scope list and how to pick a scope, and dropping Conventional-Commit types and category words.
- `ai/local/index.md`: index entry for the new file.
- `CHANGELOG.md`: entry through the changelog tool.

### Approach

1. Before any edit, post the current number-to-title list as a comment here so the renames can be undone.
2. Rename every open issue to `<scope>: <rest>`:
   - **Top-level scripts** use their bare name: `oneshot`, `interactive`, `loop`, `create-project`, `setup-owner`, `install-timer`, `uninstall-timer`, `install-claude-hooks`, `notify-unit-failure`. `lib/*` and its prompt text count as `oneshot`.
   - **Scripts under `containers/base/development-full/scripts/`** use `tool(<name>)`: `tool(cfwf)`, `tool(pre-commit-check)`, `tool(querydb)`.
   - **Hooks:** `hook(<name>)` for one hook, `hooks` for several hooks or the hook framework.
   - **Containers:** `container(<image>)` for one image, `containers` for several.
   - **Claude configuration:** `claude(settings)` for `claude-settings.json`, `claude(permissions)` for permission-mode and denial tracking.
   - **Task files:** `task(<name>)` for `tasks/<name>.md`.
   - **Agents:** `agents` for agent role and instruction behaviour.
   - **Everything else:** `tests` for bats-only work, `ci` for `.github/workflows`, `repo` for repo-wide tooling, lint or baseline.
   - An existing Conventional-Commit type (`fix:`, `feat:`, `test:`, `chore:`, `improve:`) or category word (`Security:`, `Design:`, `Track:`) is dropped, because labels already carry it. So is a leading tool name the scope makes redundant.
   - The remaining text is kept as-is apart from capitalising its first word, one typo fix (#252) and replacing an em dash (#1070).
3. Add the instruction file and index entry on a branch, through the normal PR pipeline. Under the repo's learnings rule, a `credfeto/credfeto-notes` issue is also filed describing the new convention.
4. Raise a follow-up issue on `credfeto/cs-template` so the `credfeto-github-issue` skill tells agents in any repo to prefix a "add a cfwf command" issue raised here with `tool(cfwf):`. Those agents never load this repo's `ai/local` rules (Q5, answered yes).
5. Issues opened between this plan and the renames are given a scope using the same rules, and are listed in the completion comment.

| # | New title |
| --- | --- |
| 1581 | repo: Prefix every open issue title with the tool or component it affects |
| 1580 | tests: Remove avoidable delays from the slowest bats tests (1.3-4.3 s each) |
| 1579 | tests: Split test/oneshot.bats into smaller files so bats can run it in parallel |
| 1577 | interactive: Remove the interactive script |
| 1575 | oneshot: Pivot saves the processed Issue's fingerprint even when the open PR belongs to a different Issue |
| 1574 | oneshot: Closed-Issue pivot tags and comments on whichever bot PR is open in the repo, not the Issue's own PR |
| 1573 | oneshot: Make a PR own its session transcript directory, with closing Issues linking to it |
| 1572 | oneshot: Denied-command details can leak into public GitHub comments |
| 1570 | oneshot: Pass the current GitHub login to the dispatcher /priorities endpoint |
| 1569 | oneshot: Trusted commenters: only collaborators with write access or above, minus a configurable exclusion list |
| 1568 | oneshot: PR prompt: dirty-and-behind recovery pops the stash before rebasing, so the rebase refuses to run |
| 1565 | tests: oneshot.bats: fix bats BW01 warning (exit 127) in the lib/globals BASEDIR test |
| 1564 | claude(settings): Deny agent edits to ~/.claude/projects so persisted session transcripts cannot be tampered with |
| 1563 | tool(cfwf): Match never-close label description to cs-template |
| 1556 | repo: Verify the ShellCheck 0.10 baseline in the container and tidy remaining A && B \|\| C shapes and bats BW02 warnings |
| 1554 | hooks: Stop agents editing the hook data files that govern their own Bash permissions |
| 1552 | hook(reject-obfuscated-commands): resolve_parts doesn't decode ANSI-C ($'...') escapes, missing an inline-code-flag bypass |
| 1551 | tests: project-status.bats: add bats_require_minimum_version 1.5.0 to silence BW02 warnings |
| 1550 | oneshot: Replace cmd && cmd \|\| fallback SC2015 shapes in lib/state and lib/workflow-board with explicit if/then |
| 1549 | repo: Entry-point shellcheck lint does not report findings inside sourced lib/* files |
| 1547 | container(development-tools): Pin ShellCheck 0.11 instead of Debian apt |
| 1545 | hook(reject-obfuscated-commands): Rejects script arguments that look like inline-code flags |
| 1544 | hook(enforce-background-for-long-running-commands): -c/-C skip loop doesn't recognise git's other single-token global options |
| 1541 | hooks: Two masked git -C flag-form gaps in enforce-background-for-long-running-commands and enforce-git-dash-c |
| 1540 | hook(enforce-allowed-dirs): Validate node's .github/actions/*.js script path |
| 1538 | agents: Mechanical roles must stop and report when a hook blocks a command, never route around it |
| 1537 | tool(cfwf): Read a branch's required status checks from protection and rulesets |
| 1536 | tool(cfwf): Read an issue's label history from the timeline |
| 1535 | tool(cfwf): List a repository's open issues with labels |
| 1532 | hook(enforce-background-for-long-running-commands): dotnet/npm/bun checks miss a leading flag before the subcommand |
| 1531 | `oneshot:` + the current title unchanged (it names the two accepted approval keywords, so it is not repeated here) |
| 1530 | hooks: Tab-joined word transport in PreToolUse hooks desyncs on a literal word containing a raw tab byte |
| 1529 | hook(enforce-git-dash-c): Validate config keys passed via -c / --config-env (defence in depth) |
| 1522 | oneshot: Remove the Workflow Status migration code once every board is converted |
| 1520 | create-project: Investigate copyProjectV2-from-template for Workflow project creation |
| 1516 | tool(cfwf): Rename the commands to follow the gh command style |
| 1514 | tool(cfwf): Review the workflow-board setup issue exception to cfwf issue create |
| 1513 | tool(cfwf): Create a pull request and set its Workflow Status in one step |
| 1505 | create-project: Seeds board items without setting the built-in Status |
| 1501 | tool(cfwf): Repository and account metadata lookups |
| 1500 | tool(cfwf): Look up GitHub Actions releases and tag SHAs |
| 1499 | tool(cfwf): Read and reply to a pull request's comments and reviews |
| 1498 | tool(cfwf): List a repository's open pull requests |
| 1497 | tool(cfwf): Read a pull request's state and metadata |
| 1496 | tool(cfwf): Read an issue's details, labels and comments |
| 1468 | container(agent): run_in_background likely missing a permission grant; #1281/#1374 pattern recurred on PR #1467 |
| 1462 | hooks: Shared literal_value bug: quote-adjacent concatenation misclassified as non-literal in enforce-ssh-host-and-key (and possibly enforce-allowed-dirs) |
| 1461 | hook(enforce-curl-host): Non-literal bypass-flag position not failed closed |
| 1455 | container(development-python): cfn-lint --ignore-installed pip workaround is now more exposed to daily package churn |
| 1446 | repo: pre-commit-check fails on main: shellcheck SC2015 in interactive:120, hadolint DL3066/DL3025/DL3064/SC3045 warnings |
| 1435 | oneshot: Generic pre-flight infra-failure Blocked path lacks the orchestrator:env-block trailer needed for auto-clear |
| 1432 | oneshot: pr_json_has_failed_required_check and pr_json_is_terminal only recognise conclusion == FAILURE, missing CANCELLED/TIMED_OUT/etc |
| 1419 | container(agent): Mask secret files and add an operand-based block-secret-file-reads hook; retire the Read(**/...) deny globs |
| 1416 | interactive: Harden sessions: deny .git edits in the baked claude-settings.json and use a session-scoped ssh-agent |
| 1415 | hooks: No hook blocks gh pr merge --admin (branch-protection bypass) or other dangerous gh flags |
| 1390 | interactive: Surface each PR-pipeline phase transition (simplify/code-review/security-review/coverage) as a PR comment and Discord ping, like oneshot does |
| 1389 | hooks: Drive code-execution flag denies and wrapper names from data files shared by hook, settings and tests |
| 1388 | claude(settings): Allow gh search code in permissions.allow |
| 1372 | ci: shell-tests check hangs indefinitely on 'Install bats and shfmt' (apt-get) |
| 1370 | tests: Add a drift-detecting bats test guarding against a future jq -n-from-scratch updatedInput regression (#1367 class) |
| 1343 | claude(permissions): Track complex commands/scripts blocked under --permission-mode dontAsk |
| 1339 | oneshot: Extract a shared Discord truncate/send helper in lib/discord |
| 1320 | hooks: Shared wrapper-detection gap: PreToolUse hooks only check a fixed position after a known wrapper |
| 1317 | hooks: Dedicated PreToolUse hook to restrict rm's target path |
| 1315 | claude(settings): Consider argument-scoped allow entries instead of blanket `Bash(<name> *)` for high-risk tools |
| 1303 | repo: .poutine.yml and .github/poutine.yml are dangling symlinks |
| 1297 | containers: Add run-pylint to the wrapper build-time PATH check list |
| 1292 | hook(reject-obfuscated-commands): Add check mark / cross to the Unicode normalization table |
| 1283 | oneshot: find_open_nonblocked_pr_for_repo lacks pr_is_human_driven's dependency-branch/label exemption, misclassifying bot dependency PRs |
| 1280 | oneshot: Rate-limit check runs after per-item git fetch/rebase, so a dirty repo spins uselessly for the whole rate-limited window |
| 1279 | oneshot: Per-item .orchestrator state files (invocations/fingerprint/runaway-blocked) are never reclaimed after a PR/Issue closes |
| 1274 | container(agent): Network egress lockdown (continuation of #137) |
| 1269 | task(healthcheck): Monitor live orchestrator services on nanoclaw.lan and auto-file issues for new errors/stuck items |
| 1233 | container(development-full): Add zoharbabin/claude-code-message-timestamps plugin (message-timestamps) |
| 1203 | repo: pre-commit --all-files baseline fails on main (non-executable bats files, shellcheck SC2034) |
| 1167 | hook(reject-obfuscated-commands): Track requests to extend the command-allowlist |
| 1126 | oneshot: Own ssh-agent/gpg-agent lifecycle by exact PID, replacing install-timer's ExecStartPre pattern-matching (design) |
| 1100 | container(agent): verify_hooks_fresh can fleet-brick every agent run: dies on SHA mismatch against a read-only mount the container cannot fix |
| 1073 | tests: Intermittent flake in entrypoint.bats: 'passes arguments through to claude' / 'dies when SSH_AUTH_SOCK is not set' |
| 1070 | oneshot: Prompt is too long: recurring single-phase context overflow (post #1051/#1052) |
| 309 | oneshot: Suppress raw git conflict output when non-agentic rebase hands off to agent |
| 252 | oneshot: Start planning moving the script into a more maintainable language |
| 46 | ci: Add fail-fast guard to cache-bust resolution steps in all build-development-*.yml workflows |
| 35 | container(development-full): Review wshobson/agents plugins to include in the image |

### Test strategy

- After the renames, list the open issues again and check that every title starts with an agreed scope, and that the count matches the pre-rename list.
- Instruction file: `pre-commit-check` and the AI instructions lint pass. The index entry links to the new file and back.

### Assumptions

a. Only open issues in `credfeto/credfeto-orchestrator` are in scope. Closed issues and `credfeto/credfeto-global-pre-commit` are not.
b. The Conventional-Commit type and category words are dropped rather than combined (for example not `fix(oneshot):`).
c. `pr-lint.yml` checks PR titles only, so the new issue-title format conflicts with nothing.
d. The scope list is a starting set. A new top-level script, image, hook or task gets its scope under the same rules without changing the instruction file.

### Open questions

None, ready to proceed pending approval.
