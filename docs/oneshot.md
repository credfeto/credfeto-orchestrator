# How `oneshot` works

## The simplest possible explanation

`oneshot` is the script that does one round of "go check on everything and do a bit of work if
needed, then stop." It's called `oneshot` because it isn't a long-running program — it starts,
looks at a list of work items, does at most one small piece of work, and exits. Something else
(a timer, described in [deployment-and-setup.md](deployment-and-setup.md)) runs it again a short
while later. Run it enough times in a row and, bit by bit, all the work gets done — like reading
one page of a book every time someone taps you on the shoulder, instead of trying to read the
whole book in one sitting.

## Why it works this way

An AI coding agent (Claude) can only hold so much conversation in its head at once. If `oneshot`
tried to keep one agent "session" open for an entire Pull Request from creation to merge, that
session would eventually run out of room and fail partway through — often at the worst possible
moment. So instead, every single agent invocation is a **completely fresh session with no
memory of anything before it**. Every time the agent starts, it has to figure out from scratch
what's going on by reading the actual current state on GitHub (the issue, its comments and
labels, the PR's commits and reviews, a status marker on a project board). It then does exactly
one small "phase" of work — write a plan, fix one review comment, run one test round — and
stops. `oneshot` is what decides, each time it runs, which single item most needs that one phase
done next.

## What one run actually does

1. **Fetch the priorities list.** A separate web service (not part of this repo) returns a
   sorted list of "here are the open Issues and Pull Requests across all the repos you look
   after, in priority order." See `PRIORITIES_URL` in `lib/globals`.
2. **Walk the list, highest priority first.** For each item:
   - Skip it immediately if a *different* Issue in the same repository is already being worked
     (only one active item per repository per tick — see "One repo at a time" below).
   - If it's an Issue with an already-open Pull Request driving it, switch to treating it as
     that Pull Request instead (the "pivot" — see below).
   - Skip it if it's already closed, carries the `Blocked` label, or is assigned to a human
     other than the bot.
   - Compute a **fingerprint** of its current state and compare it to the fingerprint saved the
     last time this item was looked at. If they match, nothing has changed since last time —
     skip it (see [fingerprinting.md](fingerprinting.md) for exactly how this works, including a
     real bug this caused).
   - If none of the above applies: this is the item to work on this run. Build the exact
     instructions (a generated `CLAUDE.md`, see [workflow-board.md](workflow-board.md) for what
     goes in it) and launch one agent container session against it (see
     [agent-container.md](agent-container.md)).
   - Once one item has been worked, `oneshot` stops — it does not try to work a second item in
     the same run. The next timer tick starts the search again from the top of the priority
     list.
3. **If nothing needed doing**, report a one-line summary (how many were unchanged, blocked,
   already-active, not-open, errored, or standing off for a human) and send a "no work found"
   notification.

## The Issue → Pull Request "pivot"

An Issue and the Pull Request that eventually closes it are tracked as one continuous piece of
work, even though they're different GitHub objects. Each tick, before treating something in the
priorities list as "just an Issue," `oneshot` checks: is there already an open, non-blocked Pull
Request for this repository that the bot itself created *and* has committed to? If yes, it
switches to working that Pull Request instead — the Issue's own plan-approval phase is long
done, and the interesting question now is "what's the next PR phase" (see the PR phase list in
[workflow-board.md](workflow-board.md)).

Telling "the bot is driving this PR" apart from "a human took the branch over" matters: if a
human rebases the bot's placeholder commit away and starts pushing their own work, `oneshot`
must recognise that and leave the PR alone rather than re-invoking the agent on top of someone
else's in-progress changes. This is done by checking whether the bot has authored *any* commit
still on the branch — not just who opened the PR.

## One repository at a time

Only one Issue or Pull Request per repository is actively worked in a single tick. This keeps
things simple and avoids two agent sessions racing to push conflicting commits to the same repo
checkout. A repository is marked "already active" for the rest of the tick the moment any
open, non-blocked Pull Request for it is seen in the priorities list — even one that turns out to
be unchanged and gets skipped — so a lower-priority Issue in that same repository waits its turn
rather than starting brand-new, possibly-conflicting work alongside it.

## Guard rails against an item looping forever

Because every invocation only advances one phase, a genuinely broken item (an agent that keeps
trying and failing to converge) could otherwise be re-invoked every single tick, forever, burning
time and money with nothing to show for it. Two independent budgets catch this:

- **Total invocation cap** — every Issue and every Pull Request has a maximum number of agent
  invocations `oneshot` will ever spend on it (before a Pull Request exists for an Issue; and for
  the Pull Request itself once one does). Hit the cap without converging, and the item is marked
  `Blocked` for a human to look at, with an explanation of exactly why.
- **Idle invocation cap** (Pull Requests only) — some phases legitimately don't change anything
  a human would call "progress" (a clean code review that finds nothing to fix just advances the
  board and stops). A PR that keeps getting re-invoked with nothing changing, tick after tick, is
  parked once it hits this smaller cap, rather than treated as broken outright — it might
  genuinely be done and just waiting on something (auto-merge to catch up, a human review).

Both caps reset automatically once a human clears the `Blocked` label on an item that was capped
— but *only* if it was actually blocked *because* it was capped; a PR blocked for an unrelated
reason (a failed CI check, a pending review) keeps its existing count when unblocked, since
nothing about the underlying churn problem has actually been addressed.

## What "trusted" means, and why it matters here

Anyone can comment on a public GitHub Issue or Pull Request. If the orchestrator reacted to
*every* comment, a random stranger could trigger (and pay for) an AI agent session just by
leaving a comment. So every comment, review, and inline review comment is checked against a
trusted-logins list (the repository owner, its collaborators, GitHub's own Copilot review bot,
and an explicit allow-list) before it's allowed to change anything — including whether it counts
towards a fingerprint (see [fingerprinting.md](fingerprinting.md)) or towards "is this a
human-driven PR" (see [github-integration.md](github-integration.md)).

## Assumptions

- The priorities API (`PRIORITIES_URL`) is reachable and returns well-formed JSON most of the
  time; when it isn't, `oneshot` retries a few times, then gives up loudly (dies and alerts)
  rather than silently reporting "no work found" — a masked priorities-API outage previously
  looked identical to a genuinely quiet day.
- `gh` (the GitHub CLI) is already authenticated with enough permission to read/write issues,
  PRs, labels, and comments on every repository this owner is configured to work on.
- Every agent invocation either converges within the invocation budgets above, or leaves enough
  of a trail (a pushed commit, a status comment) that the next tick can tell what to do next —
  an invocation that silently does nothing durable is the one failure mode the fingerprint/board
  mechanism can't fully protect against (see the "residual edge case" note in
  [fingerprinting.md](fingerprinting.md)).
- Only one `oneshot` process runs at a time per owner (enforced by a lock file) — running two
  concurrently against the same repositories would race on the same git checkouts and container
  names.
