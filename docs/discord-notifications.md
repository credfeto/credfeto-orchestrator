# How Discord notifications work

## The simplest possible explanation

The orchestrator runs unattended, often overnight, with nobody watching a terminal. Discord
notifications are how it says "hey, something you'd want to know about just happened" without
anyone needing to be actively watching. A message gets posted to a configured Discord webhook
URL whenever something notable happens — starting real work, finding nothing to do, running low
on disk space, or hitting an error a human should know about.

## What triggers a notification, and how repeats are suppressed

There is no single shared dedup mechanism — each notification type has its own suppression
rule, matched to what actually makes sense for that alert:

| Event | Notified when | Repeat suppression |
| --- | --- | --- |
| Work started/resumed | An agent invocation is about to begin on an Issue or Pull Request. Sub-status is enriched with round-progress detail for the four bounded-loop phases (Simplify/code-review/security-review/coverage — e.g. "AI Review (round 2 of 15)", or "AI Coverage (round 2 of 6, .NET 82%, Node 91%)"), Priority reflects the priorities feed's own numeric rank rather than an approximation from labels, a Progress field reads "Running", and an Overall field shows the item's total invocation count against its cap (#1375). | None — fires every time, every tick, same as before #1375. |
| Item observed waiting | A PR is skipped this tick because a required CI check is still pending, or because it's "settled" (auto-merge armed, nothing failed/pending) but stuck on `reviewDecision: REVIEW_REQUIRED` (#1375). Same embed shape as work started/resumed, but Progress reads "Waiting on CI" or "Waiting on human review" and the color is grey rather than green/gold. Distinct from the dedicated "PR needs approval" alert below — both can fire for the same PR. | Content-hash latch (substatus+progress+priority) — silent on every tick nothing about that content has changed, sent again immediately the moment it does. Not time-based: unlike the rolling-window alerts below, a PR can sit "Waiting on CI" for hours without a heartbeat repeat. |
| No work found | An entire tick found nothing actionable to do. The embed title carries the same count breakdown as before (how many were unchanged, blocked, already-active, not-open, errored, or standing off for a human); the embed description now also lists every skipped item individually — `<Type> #<id> in <repo>` as a link to the Issue/PR, followed by the same status text already used in the run's own log for that item (see [oneshot.md](oneshot.md)). The per-item list is truncated (with a stated count of how many more were dropped) if it would otherwise exceed Discord's embed-description size limit. | At most one per hour per owner, but only while the content (title and item breakdown) stays identical — any change is always sent immediately regardless of timing. |
| Low disk space | Available disk space drops below a configured threshold before launching a container. | At most one per hour, per owner. |
| Priorities API unreachable | The priorities feed itself could not be reached after retrying (see [oneshot.md](oneshot.md)) — distinct from the feed answering with something that failed to parse, which is not treated as a connectivity problem. | At most one per hour, shared across all owners (see below). |
| Item blocked | An Issue or Pull Request was just marked `Blocked` (see [github-integration.md](github-integration.md)). | Once per "blocked spell" — silent on every subsequent tick the item stays blocked, then re-armed the moment the item is next observed open and un-blocked. Not time-based at all. |
| PR needs approval | A Pull Request is "settled" (auto-merge armed, nothing failed/pending) but GitHub's `reviewDecision` is `REVIEW_REQUIRED` — it cannot merge purely because no approving review exists, whether one was dismissed by a later force-push or never requested at all. | At most one per hour, per repo-and-PR (not per owner, so the same PR number in two different repos never suppresses each other's alert). |
| Self-update stale | Only when systemd-invoked (gated on `ORCHESTRATOR_SELF_UPDATE_MANAGED`, a variable install-timer's generated unit declares explicitly — not systemd's generic `INVOCATION_ID`, which would also wrongly catch a manual shell descended from an unrelated systemd session — so `loop` and manual runs are unaffected): this checkout's own `HEAD` is behind `origin/main` — the systemd unit's self-update `ExecStartPre` steps did not converge (a stalled/unreachable remote is tolerated by design, but a permanently wedged merge, e.g. a stale git lock left by a killed process, previously had nothing surfacing it). The run refuses to continue this tick and exits non-zero, so `systemctl`/`journalctl` also show the unit as failed. | At most one per hour, per owner. |
| Claude error | The agent session itself returned an application-level error. | None — fires every time, every tick. |
| Rate limited | The Claude API rate-limited the current owner; work pauses until the reported reset time. | None — fires every time, every tick. |

Three different suppression shapes are in play, not one universal rule:

1. **No suppression** (work started, Claude error, rate limited) — these are expected to be rare
   or already self-limiting (a rate limit, once hit, stops further work — and further alerts —
   until it clears), so nothing extra is layered on top.
2. **A rolling one-hour window** (low disk space, priorities unreachable, PR needs approval,
   self-update stale, and no-work *when the content is unchanged*) — a small state file records
   the last time this alert actually sent, and a repeat within the hour is dropped. The no-work
   alert compares a hash of its title and item breakdown rather than the raw text, since the
   breakdown can now be long and multi-line.
3. **A persistent latch** (item blocked; item observed waiting, since #1375) — not time-based at
   all: exactly one notification per *episode* the underlying condition holds, however long that
   episode lasts. Item blocked re-arms only when the item is later seen open and un-blocked again;
   item observed waiting re-arms the moment its content (substatus, progress reason, or priority)
   actually changes — including simply advancing to a later round of the same phase, since that
   changes the enriched substatus text too.

For the rolling-window alerts, whether a **failed** attempt to reach Discord counts as "sent"
differs by alert, and this is a real, known gap rather than a settled guarantee: low disk space,
priorities-unreachable, PR-needs-approval, and self-update-stale all use a shared helper that
only records the send after a *successful* POST, so a Discord outage at the exact moment any of
them fires means the next tick retries immediately. The no-work and item-blocked alerts do
**not** have this protection — both
write their state/marker file unconditionally, even when the `curl` call itself failed — so a
Discord outage at the exact moment either of those fires can silently suppress the next
occurrence for up to an hour (no-work) or for the rest of that blocked episode (item-blocked).

Some alerts are deduplicated **per owner** (disk space is a genuinely separate concern for each
machine/owner running the orchestrator); the priorities-unreachable alert instead uses a
**single shared key** across all owners (the priorities API is one global endpoint everyone
shares — if it goes down, every owner running concurrently would otherwise flood the same
channel with one identical alert each, right when the channel's signal-to-noise matters most).

## Assumptions

- `DISCORD_WEBHOOK_URL` is optional — every notification function checks for it first and
  silently does nothing at all if it isn't configured, rather than failing the run.
- A failed Discord POST is logged as a warning but never allowed to fail (or even delay) the
  actual work the orchestrator was doing — a notification is a nice-to-have on top of the real
  job, never a dependency of it.
- One hour is an acceptable dedup window for the alerts that use a rolling window; nothing here
  supports a different window per alert kind.
- The alerts with no suppression at all (work started, Claude error, rate limited) are assumed to
  fire rarely enough in practice that flooding isn't a real concern — this hasn't been true in
  every historical incident (a persistently erroring agent could, in principle, alert every
  single tick), so treat this as a known trade-off, not a guarantee.
