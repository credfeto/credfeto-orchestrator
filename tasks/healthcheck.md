# Orchestrator fleet health check

A re-runnable prompt for checking the live orchestrator fleet on `nanoclaw.lan`.

Paste the whole of the [Prompt](#prompt) section below into a Claude Code session. It is
self-contained and safe to re-run at any time: everything it does is read-only except for
posting findings as comments on the two standing tracking issues.

## Why this exists

On 2026-08-16 the `credfeto` orchestrator service failed on **every invocation for 19.5 hours**
(~3,000 cycles) after a host reboot left an orphaned podman container name, and nothing alerted.
A Claude session was polling the fleet every 20 minutes throughout and reported "healthy" every
single time.

The reason it reported healthy is the single most important thing this prompt exists to prevent:
it was grepping the journal for `"permission_denials":[...]`, a field that **only appears inside
the result JSON emitted at the end of a successful Claude session**. No session starts, no result
JSON, no matches, scored as "quiet — healthy". Total fleet failure and perfect health produced
identical output. Broken actually looked *cleaner* than working, because a healthy window
contains 1-4 denial batches and a completely dead one contains none at all.

**The generalisable rule: every failure that stops Claude starting also silences every
Claude-derived signal.** Error-shaped monitoring is therefore structurally blind to the worst
outages. Any health check must test for the **absence of expected success** — a dead man's
switch — not merely the presence of errors.

That is why check 1 below is "are sessions completing at all", and why it comes first.

See #1361 for the full incident analysis.

## Prompt

````text
Health-check the credfeto-orchestrator fleet on nanoclaw.lan.

There are two services, one per owner:
  - credfeto-orchestrator-credfeto-credfeto.service        (user credfeto,     uid 1001)
  - credfeto-orchestrator-funfair-tech-funfair-tech.service (user funfair-tech, uid 1002)

Pull the journal ONCE per service into a file, then grep those saved files in SEPARATE
Bash calls. Do not chain ssh + grep + long diagnostic strings into one compound command;
that has repeatedly tripped the local permission classifier.

  ssh nanoclaw.lan 'sudo journalctl --since "60 min ago" -u "credfeto-orchestrator-*" --no-pager 2>&1' > /tmp/fleet.log

Work through ALL of the following. Report a short summary per check. Do not stop at the
first clean result — a quiet journal is itself ambiguous and is exactly what check 1 is for.

--- 1. ARE SESSIONS ACTUALLY COMPLETING? (most important — do this first) ---

Count completed Claude sessions in the window: grep -c '"type":"result"' /tmp/fleet.log
(equivalently, count occurrences of '"permission_denials":[').

A healthy hour normally contains several. ZERO completed sessions is an ALARM, not a quiet
period — unless the journal also shows the scheduler genuinely found no actionable work
("No actionable work items found across all priorities"). Distinguish those two cases
explicitly; they look nothing alike in the journal but both produce zero denials.

This is the dead man's switch. If it fires, something is stopping sessions from starting at
all, and every other Claude-derived signal below is meaningless.

--- 2. SERVICE / UNIT FAILURES ---

  grep -c "Failed with result" /tmp/fleet.log
  grep -c "Main process exited, code=exited, status=1" /tmp/fleet.log

Also check current unit state directly:
  ssh nanoclaw.lan 'sudo systemctl is-failed credfeto-orchestrator-credfeto-credfeto.service'
  ssh nanoclaw.lan 'sudo systemctl is-failed credfeto-orchestrator-funfair-tech-funfair-tech.service'

Any sustained non-zero count here is an alarm. The unit failing thousands of times with
nobody watching is precisely how the 19.5-hour outage went unnoticed.

--- 3. LOOPING / UNBOUNDED RE-INVOCATION ---

The scheduler re-runs every ~30-40s, so repetition alone is normal. What is NOT normal is the
same item being started over and over with no session ever completing.

  grep -oP "Starting fresh single-phase session for \K.*" /tmp/fleet.log | sort | uniq -c | sort -rn | head

Cross-reference against check 1. Many starts + zero completions = a wedged loop; investigate
before anything else. Also look for a single item dominating the window, and for:

  grep -c "unchanged but still in draft — re-running" /tmp/fleet.log
  grep -c "handing off to agent to recover" /tmp/fleet.log

A repo stuck "not clean / handing off to agent to recover" every cycle means a dirty working
tree that is never actually being recovered.

--- 4. CONTAINER / PODMAN HEALTH ---

  grep -c "already in use" /tmp/fleet.log
  grep -c "Removing leftover (non-running) container" /tmp/fleet.log
  grep -ci "oom\|out of memory" /tmp/fleet.log

If "already in use" appears, check whether it is the storage-layer orphan class (#1361):

  ssh nanoclaw.lan 'cd /tmp && sudo -n -H -u credfeto env XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus podman ps -a --filter name=orchestrator-credfeto'

If podman run rejects the name but ps -a and inspect show nothing, that is the orphan:
podman's storage layer holds the name reservation while libpod has no record of it. It is
boot-persistent and NEVER self-heals. Clearing it needs (ASK FIRST — this is a live
production action):
  podman rm -f orchestrator-<owner>

(uid 1001 = credfeto, 1002 = funfair-tech; run from a cwd other than /home/markr, since
sudo -u <owner> cannot chdir there.)

--- 5. HOST RESOURCES ---

  ssh nanoclaw.lan 'df -h / /home 2>&1'
  ssh nanoclaw.lan 'uptime 2>&1'

The orchestrator refuses to launch below MIN_DISK_SPACE_KB (10 GB). Also check whether the
host rebooted recently, which is what triggered the #1361 outage:

  ssh nanoclaw.lan 'last -x reboot shutdown 2>&1 | head -5'

A reboot in the window is a strong prompt to check 4 — an unclean shutdown can strand a
container name.

--- 6. RATE LIMITS / API ERRORS ---

  grep -ci "rate limit\|429" /tmp/fleet.log
  grep -c '"is_error":true' /tmp/fleet.log

--- 7. NEW PERMISSION DENIALS ---

  grep -o '"permission_denials":\[[^]]*\]' /tmp/fleet.log | sort | uniq -c

Empty arrays are NOT findings. For non-empty ones, report ONLY genuinely new gaps. Do not
re-report anything already known to be blocked by design:

  - git commands missing the `git -C <dir>` prefix
  - git worktree add
  - timeout, dotnet tool install, dotnet new tool-manifest
  - self-introspection into /opt or /workspace/rules after a denial (neither is in --add-dir)
  - `for` / `while` shell loop constructs
  - reads of ~/.claude (outside the trust boundary)
  - any read/cat/ls/grep/find of .database files
  - gh api user (deliberately excluded)
  - gh api graphql piped into python3 -c (known compound-pipe behaviour)

Post genuinely new findings as comments on the standing tracking issues:
  - simple single commands            -> credfeto/credfeto-orchestrator#1342
  - complex commands / scripts        -> credfeto/credfeto-orchestrator#1343

Both are labelled Blocked so they are not picked up as work items. Leave them that way.

--- 8. STUCK / STALE WORK ---

  gh pr list --repo credfeto/credfeto-orchestrator --state open --json number,title,isDraft,mergeStateStatus,updatedAt

Flag anything DIRTY (merge conflict) or open with no movement for over ~24h. Verify PR state
live with `gh pr view <n> --json state,mergedAt` rather than trusting earlier assumptions —
PRs merge while you work.

--- REPORTING ---

Summarise per check: OK / ALARM / needs attention, with counts and evidence.

Rules:
  - Do NOT report "all healthy" on the basis of a quiet journal alone. Check 1 must have
    positively confirmed sessions are completing, or that the scheduler legitimately found
    no work.
  - Do NOT make code changes, open PRs, or run destructive/production commands
    (podman rm -f, systemctl restart, killing processes) without asking first.
  - Do file or comment on tracking issues for genuinely new findings.
````

## Related

- #1361 — the incident this prompt was written in response to.
- #1342 / #1343 — the standing permission-denial tracking issues findings go to.
- [docs/agent-container.md](../docs/agent-container.md) — how the container is locked down.
- [docs/deployment-and-setup.md](../docs/deployment-and-setup.md) — how the services are installed.
