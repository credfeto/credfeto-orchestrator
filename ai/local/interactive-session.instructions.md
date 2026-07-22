# Interactive Session Instructions

[Back to Local Instructions Index](index.md)

> Load when: starting any interactive Claude Code session in this repository.

## Full Lifecycle — Always

Interactive sessions in this repo must follow the same end-to-end workflow as the non-interactive orchestrator. Writing the code is not the finish line — work must be seen through to a merged (or human-review-ready) PR before stopping.

The orchestrator workflow is defined in [agent-roles.instructions.md](../global/agent-roles.instructions.md) under the **Orchestrator** and related role sections. Apply it in full:

### New issue (no existing PR)

1. Post an implementation plan as an issue comment (exact format in `agent-roles.instructions.md`).
2. Set the Workflow board status to **Planning** and add the `Blocked` label.
3. **Stop.** Do not proceed until a human approves the plan (board status set to **Approved**, or approval comment if no board is configured) and removes `Blocked`.
4. Once approved: run Changelog in **placeholder** mode (a stub entry, best-guess `Type`, message `TBD - to be finalized after review`) — no code exists yet. Commit `CHANGELOG.md` alone, push, and create the PR as draft. Skip this placeholder step entirely if the repo hits the template-repo skip condition in `changelog.instructions.md`; start the next step directly instead.
5. Continue with the PR workflow below.

### Existing PR or PR just created

1. Implement the code, running tests and linting as you go (Code Writer / Code Tester / Code Reviewer dev loop).
2. Once satisfied: run Changelog in **correction** mode — read `git diff origin/main...HEAD`, remove the placeholder entry and add the corrected one. Commit code+tests as one commit and `CHANGELOG.md` as a separate commit, push.
3. Run `/simplify` against the diff (up to `MAX_REVIEW_ITERATIONS` rounds; board status **AI Simplify**). If it changed any files: run Changelog (correction) again against the resulting diff, commit code and (if the entry changed) `CHANGELOG.md` separately, push, re-run.
4. Run `/code-review --comment` (up to `MAX_REVIEW_ITERATIONS` rounds; board status **AI Review**); fix each inline finding in its own commit. After each fix, run Changelog (correction) and commit `CHANGELOG.md` separately if the entry changed, then push.
5. Run `/security-review` (up to `MAX_REVIEW_ITERATIONS` rounds; board status **AI Security Review**); fix each finding in its own commit. After each fix, run Changelog (correction) and commit `CHANGELOG.md` separately if the entry changed, then push.
6. Set Workflow board to **Human Review** and enable auto-merge:

   ```bash
   gh pr merge --auto --merge <number> --repo <owner/repo>
   ```

   If auto-merge is unavailable: `gh pr ready <number> --repo <owner/repo>`.

### Workflow board

Update the board status at every stage transition (Not Started → Development → AI Simplify → AI Review → AI Security Review → AI Coverage → Human Review; AI Coverage enforces the whole-repo coverage ratchet, see `docs/workflow-board.md` and `coverage-ratchet.instructions.md`). Commands are in `agent-roles.instructions.md` under **Workflow Board**.

## Quality gates (mandatory before any commit)

- `shellcheck oneshot loop` — must pass with no findings.
- `bats test/` — full suite must pass, including new tests for any new behaviour.
- `dotnet changelog` — add or correct the changelog entry (placeholder or correction mode, per the lifecycle above) before each relevant commit, unless the repo hits the template-repo skip condition.
- All pre-commit hooks must pass; never use `--no-verify`.
