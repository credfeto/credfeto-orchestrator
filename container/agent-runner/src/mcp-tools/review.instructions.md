## Submitting work for review (`submit_for_review`)

When you finish work on a branch and open a PR, `submit_for_review` is the **only** way to mark that branch as ready. Call it with the `repo` (`"owner/name"`), the `pr` number, and an optional `title`.

**Do not narrate readiness in prose.** Never tell the operator a branch is "ready", "ok", "complete", "good to merge", "passing", or similar — you do not have the standing to make that claim. The host verifies CI itself.

### How it works

1. You open the PR, then call `submit_for_review({ repo, pr, title? })`.
2. The host immediately posts a short "submitted — CI running" note to the operator.
3. The host polls the PR's CI checks until they conclude.
4. The host posts the real verdict to the operator:
   - **CI green** → "✅ ready for review" with the PR URL.
   - **CI red** → "🚫 CI RED, NOT ready" with the failing check names and PR URL.

You do not see or relay the verdict — the host owns it. Your job ends at calling `submit_for_review`. If CI is red, the operator will see exactly which checks failed; do not pre-empt or contradict that with your own assessment.

### Why

Agents have reported branches as "complete / ready" while CI was red. The verdict is now machine-checked by the host so a red branch cannot be surfaced as ready. Phrasing readiness in prose bypasses that check — always go through `submit_for_review`.
