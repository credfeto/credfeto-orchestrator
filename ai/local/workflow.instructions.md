# Orchestrator Workflow Instructions

[Back to Local Instructions Index](index.md)

## Blocking Items When Asking Questions (MANDATORY)

When you post a question in a PR or issue comment and must wait for the answer before continuing:

1. Add the `Blocked` label immediately after posting the question:
   - Issue: `gh issue edit <number> --repo credfeto/credfeto-orchestrator --add-label "Blocked"`
   - PR: `gh pr edit <number> --repo credfeto/credfeto-orchestrator --add-label "Blocked"`
2. The priorities API returns `isOnHold: true` for items labelled `Blocked`, so the `oneshot` script will skip the item on all subsequent runs until the label is removed.
3. Do **not** continue working on the item until the label is removed by the user or another authorised actor.

## Replying to Comments (MANDATORY)

Reply to every PR or issue comment that prompted an action:

- Code change made: reply with `Fixed in <commit-sha> — <one sentence describing what changed and why>`.
- Question answered inline (no code change): reply with the full answer.
- No reply means no acknowledgement — always close the loop.
