# How the Workflow board works

## The simplest possible explanation

Imagine a physical whiteboard with columns like "To Do," "In Progress," and "Done," and you move
a sticky note from column to column as work happens. The "Workflow" board is exactly that, but
as a [GitHub Project (v2)](https://docs.github.com/en/issues/planning-and-tracking-with-projects)
board instead of a physical one. Every Issue and Pull Request the orchestrator works on gets a
card on this board, and the AI agent moves that card across a fixed set of columns
("Not Started" → "Planning" → "Approved" → "Development" → ... → "Complete") as it works. A
human's main job is to sit at one specific column — "Approved" — and decide whether to let the
agent past it.

## Why it exists

An AI agent should never be allowed to just start writing code the moment someone opens an
Issue. It needs to (a) show its plan first, and (b) wait for an actual human to say "yes, do
that" before touching anything. The board is how that gate is implemented and made visible:
the agent posts a plan as a comment, then sets its own card to "Planning" and stops. A human
reads the plan, and only they can move the card to "Approved" — no code gets written until that
happens.

## The Workflow Status field and its options, in order

| Status | Set by | Meaning |
| --- | --- | --- |
| Not Started | `oneshot` | Card created; nothing has happened yet. For a PR this is only a lasting state when the PR has no linked issue at all (e.g. a dependency-update PR) — otherwise `oneshot` immediately mirrors the linked issue's status onto it, floored at "Development" (see [Keeping a PR's card in step with its issue's](#keeping-a-prs-card-in-step-with-its-issues) below). |
| Planning | the agent | A plan has been posted; waiting for human review. |
| Approved | **a human, manually** | The plan is approved — the agent may start implementing. |
| Development | the agent | Actively writing code / fixing things. Set only once the draft pull request (with its placeholder CHANGELOG.md entry) has actually been created — not at the start of implementation — so a session that dies mid-step (e.g. after the placeholder commit but before the PR is opened) doesn't leave the board looking further along than the work really is ([#1262](https://github.com/credfeto/credfeto-orchestrator/issues/1262)). |
| AI Simplify | the agent | Running the automated cleanup pass before review. |
| AI Review | the agent | Running an automated code review pass. |
| AI Security Review | the agent | Running an automated security review pass. |
| AI Coverage | the agent | Checks that the branch's overall test coverage has not dropped below `main`'s, per language, against the `COVERAGE.md` committed on `main` (see [coverage-ratchet.instructions.md](https://github.com/credfeto/cs-template/blob/main/ai/global/coverage-ratchet.instructions.md)). This is the last automated gate, placed after both review passes so it also catches coverage regressions those later commits could otherwise introduce unchecked. A drop sends the card back to Development; a pass regenerates `COVERAGE.md` on the branch. |
| Human Review | the agent | Everything automated has passed. A later invocation (Finalize, below) still has to enable auto-merge — reaching this status does not by itself mean that has happened yet. |
| Complete | (implicit — the PR merges) | Done. |

Only one of these transitions is ever made by a human: **Approved**. Every other column is moved
through entirely by the agent itself as it works. This is deliberately the single, simple, highly
visible decision a human has to make — everything downstream of it is automatic.

## What `oneshot` reads from the board vs. what it writes

- **Reads**: whether an Issue's card currently says "Approved" (`fetch_board_approved_items`,
  `issue_plan_approved`). This is the one piece of board state that changes what `oneshot` itself
  decides to do — see [fingerprinting.md](fingerprinting.md) for the bug that happened when this
  fact was invisible to the fingerprint that gates re-checking an Issue at all.
  A related but distinct read is "has this Issue's plan ever been approved, regardless of how far
  the card has since moved on" (`issue_plan_approved_or_later` — ordinal, not exact-match; see its
  header comment in `lib/workflow-board` for the full rationale and its call sites). Only
  `issue_plan_approved`'s exact-match result feeds the fingerprint (#1321).
- **Writes**: the card's status, at specific well-defined points — e.g. "Not Started" the first
  time an Issue is ever touched, a PR's card mirrored forward from its linked issue on every
  tick (see [Keeping a PR's card in step with its issue's](#keeping-a-prs-card-in-step-with-its-issues)
  below), or whatever status the agent itself decided to move to as part of its own turn (the
  agent is the one actually setting "Development," "AI Review," etc. — see `_build_wf_section`
  in `lib/prompts`, which hands the agent the raw GitHub Project field/option IDs it needs to
  make that GraphQL call itself).

## How a Pull Request actually moves through these columns

Once an Issue's plan is Approved and the agent opens a draft Pull Request, the PR itself takes
over driving the board through a fixed sequence of phases (see `build_pr_claude_md` in
`lib/prompts`), one phase per agent invocation:

1. **Setup / rebase** — check out the branch, sync labels from the linked issue, rebase if the
   PR has fallen behind `main`.
2. **Wait for CI** — if a required check is still running, do nothing this tick; just wait.
3. **Fix outstanding work** — a failed check, an unaddressed review comment, or linked-issue
   feedback. Fix it, commit, push, stop; CI reruns and the next tick continues.
4. **Simplify** — run an automated cleanup pass. If it changes anything, commit/push and stop
   (CI must re-verify the new commit first); if it's already clean, advance to review.
5. **Code review** — run one automated review round. Findings get fixed in their own commit,
   or, if clean, the board advances to security review.
6. **Security review** — same shape as code review, for security-specific findings.
7. **Coverage**: the last automated gate. It compares the branch's live per-language coverage
   against the Overall figures in `COVERAGE.md` as committed on `main` (no PR comment; a
   non-code-only branch — dependency bump, or a workflow/SQL/shell/Docker/docs-only change — or a
   `main` with no `COVERAGE.md` yet both skip straight to a pass), and
   if any language's branch coverage is lower, sends the board back to Development instead of
   advancing, so more tests get written before the PR reaches a human. On a pass, `COVERAGE.md` is
   regenerated on the branch and committed, so it carries the new baseline into `main` once the PR
   merges. Placed after both review phases (not right after Development) because those phases can
   themselves commit production code, and an earlier gate would let those commits degrade coverage
   unchecked.
8. **Finalize** — enable auto-merge (or mark the PR ready if auto-merge isn't available) and
   stop. GitHub takes it from here.

Each of these is its own single agent invocation — never more than one phase per session (see
[oneshot.md](oneshot.md) for why: a fresh, memoryless session per invocation is what keeps each
one small enough to actually fit in the agent's context window). Progress across phases works
because every phase leaves something durable in GitHub for the next invocation to discover
(a pushed commit, an updated board status, or at minimum a status comment) — a phase that does
nothing durable is invisible to the next tick and the workflow stalls.

## Keeping a PR's card in step with its issue's

An Issue and its Pull Request are two separate items on the board, each with its own
independent Workflow Status card — nothing about GitHub Projects keeps them in sync with each
other automatically. That used to cause a real failure: `oneshot` stamped every newly-touched
PR's card with a hardcoded "Not Started", regardless of what its linked issue's card already
said. A PR only ever exists once its issue has passed the human Approved gate, so the issue's
card is always further along by then — but if the session that opened the draft PR died before
also advancing the *PR's own* card to "Development" (see the table entry above), the PR was left
looking, to any later PR-phase session reading only its own card, exactly like an issue that was
never approved at all. That's what happened in
[credfeto/recommendations-defi-dashboard#412](https://github.com/credfeto/recommendations-defi-dashboard/pull/412):
the PR-phase session read "Not Started" on the PR's own card, incorrectly fell back to the
Issue-workflow's Approved gate (which does not apply once a PR already exists — see
`agent-roles.instructions.md`), and blocked instead of finishing the deferred implementation
([#1276](https://github.com/credfeto/credfeto-orchestrator/issues/1276)).

`sync_pr_workflow_status_from_linked_issues` (`lib/workflow-board`) fixes this by mirroring
every PR's linked issue's Workflow Status onto the PR's own card, every tick — not just on
first touch, so an already-stuck PR self-heals without a human having to intervene:

- **One-directional**: issue → PR only. The PR's card is never read back onto the issue's — the
  Approved gate is enforced solely on the issue's card, and nothing may ever write "Approved"
  itself (see Assumptions below); mirroring in the other direction would let PR-phase progress
  leak "AI Review"/"Complete" etc. back onto the issue.
- **Forward-only**: the PR's card is never moved backward. Once a PR starts driving its own
  status through AI Simplify / AI Review / AI Coverage / etc. it legitimately runs ahead of its
  issue, and the mirror must never pull it back down to match.
- **Floored at "Development"**: a PR's card is never mirrored below "Development", regardless of
  the issue's exact recorded status — a PR's mere existence is proof its issue was approved, even
  if the issue-phase session that created the PR died before writing "Development" onto the
  issue's own card too.
- **No linked issue**: PRs with no closing-issue reference at all (dependency-update PRs) keep
  the old first-touch-only "Not Started" initialisation, since `build_pr_claude_md`'s
  dependency-PR branch never reads board status in the first place.

## What happens if the "Workflow" project doesn't exist yet for a repo

A bot account cannot create a GitHub Project under a personal GitHub account — only the human
repository owner can. If `oneshot` can't find a usable "Workflow" project for a repo it's
working on, it can't gate anything on board approval at all; instead, it falls back to a
comment-based approval check (a human posting a literal "approved" / "go ahead" / "looks good" /
"lgtm" comment after the plan), and it files a one-time tracking issue in that repo explaining
that the owner needs to run `create-project --repo <owner/repo>` (see
[deployment-and-setup.md](deployment-and-setup.md)) to set the board up properly.

## Assumptions

- Only a human can move a card to "Approved." Nothing in this codebase's own logic ever writes
  that specific status itself — if it ever did, the entire plan-approval gate this board exists
  to enforce would be meaningless.
- The board's project ID and field/option IDs, once discovered for a repository, rarely change,
  so they're cached (in-memory for the current run, and to disk with a time-to-live across runs)
  to avoid a GraphQL round-trip on every single tick.
- A repository's board is entirely optional — the comment-based fallback above means the
  orchestrator still works, just with a less visible approval mechanism, for a repo whose owner
  hasn't set one up yet.
