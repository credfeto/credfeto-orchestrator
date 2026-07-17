# Architecture

## The simplest possible explanation

This project is an unattended system that watches GitHub Issues and Pull Requests across a set
of repositories, and whenever one of them needs the next small step of work done, it starts up
an AI coding agent (Claude) in a locked-down sandbox to do exactly that one step, then shuts the
sandbox back down. It repeats this, one small step at a time, on a fixed schedule, forever — like
a very patient, very careful assistant who checks a to-do list every 30 seconds, does the next
tiny thing on the top item if anything's actually changed, and then goes back to waiting.

## The moving pieces, and how they fit together

```text
 systemd timer (deployment-and-setup.md)
        │  fires every N seconds
        ▼
   oneshot (oneshot.md)
        │  1. fetches the priorities list
        │  2. picks the highest-priority item that needs attention
        │  3. compares its fingerprint (fingerprinting.md) to detect "did anything change"
        │  4. if something changed: builds instructions and launches...
        ▼
  agent container (agent-container.md)
        │  a fresh, locked-down, throwaway sandbox
        │  built from a chain of base images (base-image-chain.md)
        │  runs Claude Code for exactly one phase of work
        ▼
   GitHub (github-integration.md, workflow-board.md)
        │  the plan/comment/label/board changes the agent just made
        │  become the durable record of what happened
        ▼
   Discord (discord-notifications.md)
           a human gets told about anything notable, without watching a terminal
```

Every one of the linked documents above covers one piece of this in plain language. This
document is the map connecting them — read it first, then follow whichever links match what
you're trying to understand.

## One tick, start to finish

1. A systemd timer fires `oneshot` on a fixed schedule (default every 30 seconds), once per
   configured GitHub account ("owner") the orchestrator works on behalf of — see
   [deployment-and-setup.md](deployment-and-setup.md) for how an owner and its timer get set up
   in the first place.
2. `oneshot` asks a separate priorities web service for the current list of open Issues and
   Pull Requests across every repository that owner cares about, sorted by priority.
3. It walks that list, skipping anything that's closed, `Blocked`, being driven by a human, or
   **unchanged since the last time it was checked** — a "fingerprint" comparison (see
   [fingerprinting.md](fingerprinting.md)) is what decides "unchanged," and getting this wrong
   is exactly the kind of bug that leaves something silently stuck for days.
4. The first item that genuinely needs attention gets one single step of work: `oneshot` builds
   a fresh set of instructions (including, for an Issue, whether its plan has been approved on
   a GitHub Project board — see [workflow-board.md](workflow-board.md)) and starts a brand-new,
   locked-down container (see [agent-container.md](agent-container.md), itself built from a
   chain of increasingly specialised images — see [base-image-chain.md](base-image-chain.md))
   to run one Claude Code session against it.
5. That session does exactly one thing — write a plan, fix one review comment, run one review
   round — then stops. It records what it did entirely through normal GitHub actions (a
   comment, a commit, a label, a board-status change — see
   [github-integration.md](github-integration.md)), because the *next* tick's agent session will
   have absolutely no memory of this one and must be able to reconstruct the whole situation
   from GitHub state alone.
6. Anything a human should know about — work starting, nothing to do, a problem, an item
   getting stuck — is posted to Discord (see [discord-notifications.md](discord-notifications.md))
   so nobody has to be watching a terminal to find out.
7. `oneshot` exits. The timer fires again a short while later, and the whole thing repeats.

## Why it's built this way

Two constraints shape almost every design decision in this codebase:

- **An AI agent's context window is finite.** Trying to keep one long conversation open across
  an entire Issue-to-merged-PR lifecycle would eventually overflow and fail, often partway
  through something important. The fix is to never try: every invocation is a fresh session that
  reconstructs its understanding from GitHub state and does one bounded step (see
  [oneshot.md](oneshot.md)'s "why it works this way").
- **Nobody is watching.** This runs unattended, often overnight, across many repositories at
  once. Every failure mode that would normally just get noticed and fixed by a human sitting
  there instead has to be handled by code: a stuck item needs an automatic escalation
  (`Blocked` + an explanation — [github-integration.md](github-integration.md)), a broken
  container needs to fail loudly and distinctly from a broken *task*
  ([agent-container.md](agent-container.md)), and a human still needs to *find out* something
  happened without watching a terminal ([discord-notifications.md](discord-notifications.md)).

## Assumptions

- Every document linked from here describes the system as it exists today; if the code changes,
  the corresponding doc (and this map) should be updated in the same change — a stale
  architecture doc is worse than no doc, since it actively misleads.
- Exactly one agent session per `oneshot` run, across *all* repositories, not one-per-repository
  (see [oneshot.md](oneshot.md)) — a deliberate simplicity choice, not a hard technical limit. It
  keeps the whole system easy to reason about at the cost of not parallelising work at all within
  a single tick; the next tick, moments later, is what picks up the next item.
- A human is assumed to be reachable via Discord and via GitHub notifications within a
  reasonable time of being needed (an approval, an escalation) — nothing here has a fallback for
  "nobody ever looks."
