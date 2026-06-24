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
4. Once approved: implement, run tests and linting, add changelog entry, commit, push, create PR as draft.
5. Continue with the PR workflow below.

### Existing PR or PR just created

1. Run `/code-review --comment` (up to `MAX_REVIEW_ITERATIONS` rounds); fix all inline findings.
2. Run `/security-review` (up to `MAX_REVIEW_ITERATIONS` rounds); fix all findings.
3. Set Workflow board to **Human Review** and enable auto-merge:

   ```bash
   gh pr merge --auto --merge <number> --repo <owner/repo>
   ```

   If auto-merge is unavailable: `gh pr ready <number> --repo <owner/repo>`.

### Workflow board

Update the board status at every stage transition (Not Started → Development → AI Review → AI Security Review → Human Review). Commands are in `agent-roles.instructions.md` under **Workflow Board**.

## Quality gates (mandatory before any commit)

- `shellcheck oneshot loop` — must pass with no findings.
- `bats test/` — full suite must pass, including new tests for any new behaviour.
- `dotnet changelog` — add a changelog entry before committing.
- All pre-commit hooks must pass; never use `--no-verify`.
