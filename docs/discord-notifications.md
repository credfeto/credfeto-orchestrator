# How Discord notifications work

## The simplest possible explanation

The orchestrator runs unattended, often overnight, with nobody watching a terminal. Discord
notifications are how it says "hey, something you'd want to know about just happened" without
anyone needing to be actively watching. A message gets posted to a configured Discord webhook
URL whenever something notable happens — starting real work, finding nothing to do, running low
on disk space, or hitting an error a human should know about.

## What triggers a notification

| Event | Notified when |
| --- | --- |
| Work started | An agent invocation is about to begin on an Issue or Pull Request. |
| No work found | An entire tick found nothing actionable to do (includes a breakdown: how many were unchanged, blocked, already-active, not-open, errored, or standing off for a human). |
| Low disk space | Available disk space drops below a configured threshold before launching a container. |
| Priorities API unreachable | The priorities feed itself could not be reached after retrying (see [oneshot.md](oneshot.md)) — distinct from the feed answering with something that failed to parse, which is not treated as a connectivity problem. |
| Item blocked | An Issue or Pull Request was just marked `Blocked` (see [github-integration.md](github-integration.md)). |
| Claude error | The agent session itself returned an application-level error. |
| Rate limited | The Claude API rate-limited the current owner; work pauses until the reported reset time. |

## Deduplication: why the same alert doesn't spam every single tick

Nobody wants "disk space is low" repeated every 30 seconds forever. Every notification type
tracks, in a small state file, the last time it actually sent — and suppresses re-sending the
same kind of alert again until an hour has passed. A **failed** attempt to reach Discord itself
does **not** count as "sent": if the Discord webhook is down at the exact moment a real problem
is being reported, the next tick will try again immediately, rather than silently going quiet
for the next hour about an alert that never actually reached anyone.

Some alerts are deduplicated **per owner** (disk space is a genuinely separate concern for each
machine/owner running the orchestrator); others are deduplicated on a **single shared key**
across all owners (the priorities API is one global endpoint everyone shares — if it goes down,
every owner running concurrently would otherwise flood the same channel with one identical
alert each, right when the channel's signal-to-noise matters most).

## Assumptions

- `DISCORD_WEBHOOK_URL` is optional — every notification function checks for it first and
  silently does nothing at all if it isn't configured, rather than failing the run.
- A failed Discord POST is logged as a warning but never allowed to fail (or even delay) the
  actual work the orchestrator was doing — a notification is a nice-to-have on top of the real
  job, never a dependency of it.
- One hour is an acceptable dedup window for every alert type that uses it; nothing here supports
  a different window per alert kind.
