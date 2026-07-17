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
| Work started/resumed | An agent invocation is about to begin on an Issue or Pull Request. | None — fires every time, every tick. |
| No work found | An entire tick found nothing actionable to do (includes a breakdown: how many were unchanged, blocked, already-active, not-open, errored, or standing off for a human). | At most one per hour per owner, but only while the message text stays identical — a *changed* message (a different breakdown) is always sent immediately regardless of timing. |
| Low disk space | Available disk space drops below a configured threshold before launching a container. | At most one per hour, per owner. |
| Priorities API unreachable | The priorities feed itself could not be reached after retrying (see [oneshot.md](oneshot.md)) — distinct from the feed answering with something that failed to parse, which is not treated as a connectivity problem. | At most one per hour, shared across all owners (see below). |
| Item blocked | An Issue or Pull Request was just marked `Blocked` (see [github-integration.md](github-integration.md)). | Once per "blocked spell" — silent on every subsequent tick the item stays blocked, then re-armed the moment the item is next observed open and un-blocked. Not time-based at all. |
| Claude error | The agent session itself returned an application-level error. | None — fires every time, every tick. |
| Rate limited | The Claude API rate-limited the current owner; work pauses until the reported reset time. | None — fires every time, every tick. |

Three different suppression shapes are in play, not one universal rule:

1. **No suppression** (work started, Claude error, rate limited) — these are expected to be rare
   or already self-limiting (a rate limit, once hit, stops further work — and further alerts —
   until it clears), so nothing extra is layered on top.
2. **A rolling one-hour window** (low disk space, priorities unreachable, and no-work *when the
   message is unchanged*) — a small state file records the last time this alert actually sent,
   and a repeat within the hour is dropped.
3. **A persistent latch** (item blocked) — not time-based at all: exactly one notification per
   *episode* of being blocked, however long that episode lasts, re-armed only when the item is
   later seen open and un-blocked again.

For the rolling-window alerts, whether a **failed** attempt to reach Discord counts as "sent"
differs by alert, and this is a real, known gap rather than a settled guarantee: low disk space
and priorities-unreachable both use a shared helper that only records the send after a
*successful* POST, so a Discord outage at the exact moment either fires means the next tick
retries immediately. The no-work and item-blocked alerts do **not** have this protection — both
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
