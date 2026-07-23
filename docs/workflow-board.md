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
| Not Started | `oneshot` | Card created; nothing has happened yet. |
| Planning | the agent | A plan has been posted; waiting for human review. |
| Approved | **a human, manually** | The plan is approved — the agent may start implementing. |
| Development | the agent | Actively writing code / fixing things. |
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

- **Reads**: whether an Issue's card currently says "Approved" (`fetch_board_approved_items`).
  This is the one piece of board state that changes what `oneshot` itself decides to do — see
  [fingerprinting.md](fingerprinting.md) for the bug that happened when this fact was invisible
  to the fingerprint that gates re-checking an Issue at all.
- **Writes**: the card's status, at specific well-defined points — e.g. "Not Started" the first
  time an item is ever touched, or whatever status the agent itself decided to move to as part
  of its own turn (the agent is the one actually setting "Development," "AI Review," etc. — see
  `_build_wf_section` in `lib/prompts`, which hands the agent the raw GitHub Project field/option
  IDs it needs to make that GraphQL call itself).

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
   dependency-only branch or a `main` with no `COVERAGE.md` yet both skip straight to a pass), and
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
