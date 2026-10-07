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

--- 7. STALLED SESSIONS AND PERMISSION DENIALS ---

Every agent session appends one tab-separated line to a per-owner, per-day file:

  ~<owner>/.local/state/orchestrator/<owner>/session-denials.YYYY-MM-DD

Fields: timestamp, repo, item type, item id, denial count, stalled (1/0), quit after a tool
denial (1/0), denied command names (comma-separated, "-" for none). Read today's and
yesterday's files for each owner, or every date in the window when asked to check a longer
period (run from a cwd other than /home/markr):

  ssh nanoclaw.lan 'sudo -n -u credfeto cat /home/credfeto/.local/state/orchestrator/credfeto/session-denials.YYYY-MM-DD'
  ssh nanoclaw.lan 'sudo -n -u funfair-tech cat /home/funfair-tech/.local/state/orchestrator/funfair-tech/session-denials.YYYY-MM-DD'

Fallback for a date with no session-denials file (the cat above fails with "No such file"):
the date predates the file, or it was pruned, so count the quit sessions from the journal
instead. Pull that date's journal ONCE per service into its own file, as above (one unit per
file, so every line belongs to that owner's sessions):

  ssh nanoclaw.lan 'sudo journalctl --since "YYYY-MM-DD" --until "YYYY-MM-DD+1" -u credfeto-orchestrator-credfeto-credfeto.service --no-pager 2>&1' > /tmp/quit-credfeto-YYYY-MM-DD.log
  ssh nanoclaw.lan 'sudo journalctl --since "YYYY-MM-DD" --until "YYYY-MM-DD+1" -u credfeto-orchestrator-funfair-tech-funfair-tech.service --no-pager 2>&1' > /tmp/quit-funfair-tech-YYYY-MM-DD.log

(YYYY-MM-DD+1 is the following date.) Then, in a SEPARATE Bash call per file, count the
sessions whose final message says Claude quit because a tool was denied, per repo. Only the
agent's final message is classified, never the orchestrator's own log lines around it: its
"✓ Completed one workflow phase" line would otherwise match the workaround rule for every
session, and its "no progress this session" line the give-up rule. oneshot echoes the final
message as plain lines, with no prefix, from the same oneshot[PID] as that item's "Checking
<type> #<id> in <repo>" line, after its "Starting new Claude session" line. So the awk below
keeps a line only when all of these hold:

  - it carries the same oneshot[PID] field as the "Checking" line. This drops the container's
    own output (including its JSON result line), podman and systemd lines, and the "Claude
    reported N permission denial(s)" warning with its "- Bash: ..." list, which oneshot prints
    from a command-substitution subshell with a different PID;
  - it comes after "Starting new Claude session", which drops the dirty-branch warning and its
    git status lines printed before the session;
  - it does not start with "! " or with a non-ASCII character. lib/core's die, success, info
    and warn helpers prefix every orchestrator line with ✗, ✓, → or !, so this drops "✓
    Completed one workflow phase", "→ PR #N ...: no progress this session", "→ PR #N ...: not
    charging" and the rest. The exception is "→ Claude error: <message>": a session that ended
    in error prints its final message only there, so that prefix is removed and the message
    kept.

The awk is plain ASCII on purpose (it tests for a non-ASCII first character rather than
naming the markers), and reads the PID from field 5 of journalctl's default short output
format. For the same reason "don[^a-z ]{1,3}t", "can[^a-z ]{1,3}t" and "couldn[^a-z ]{1,3}t"
accept a curly apostrophe without naming it: it is three bytes under a C locale and one
character under UTF-8, and both fit. One message can span several journal lines, so the kept lines are gathered under the
most recent "Checking" line and each session is classified and counted once:

  awk 'function classify() {
         t = text
         while (match(t, /([a-z]n[^a-z ]{1,3}t|(^|[^a-z])(not|never|no|cannot))( yet)?( be| been)? (finished|completed|pushed|succeeded)|(^|[^a-z])(nothing|no)( [a-z]+){0,3} (was|were|has been|have been|is|are) (finished|completed|pushed|succeeded)/)) t = substr(t, 1, RSTART - 1) " " substr(t, RSTART + RLENGTH)
         if (text ~ /bash( tool| commands?| calls?)? (is|are|was|were|has been|have been|(is|are) being) (now |completely |entirely |fully )?(denied|disabled|blocked)|bash( tool)? (is|was|has been) no longer (allowed|available|permitted)|don[^a-z ]{1,3}t ask.{0,2} mode/ \
             && text ~ /(cannot|can not|can[^a-z ]{1,3}t|couldn[^a-z ]{1,3}t|could not|unable to) (continue|proceed)|(cannot|can not|can[^a-z ]{1,3}t|couldn[^a-z ]{1,3}t|could not|unable to) make any progress|no progress|stopping here|have stopped|stopped (work|the session)|stopped before (doing|starting|any)|giving up|gave up|(a |the )?(permission )?denial stopped me|stopped me from|nothing( below| else)? (has been|was) done|(couldn[^a-z ]{1,3}t|could not) do anything|re-?invoke me|to continue, (either )?allow|rest of (the|this) session|(partway|part way|halfway) through (the|this) session|(denied|disabled|blocked) (in|for) (the|this) session|bash( tool)? (is|was|has been) (now (denied|disabled)|no longer (allowed|available|permitted))/ \
             && t !~ /(^|[^a-z])(instead|finished|completed|pushed|succeeded)([^a-z]|$)|worked (round|around)|(is|are|was|were) complete([^a-z]|$)/) quits[repo]++
       }
       / Checking .* #[0-9]+ in [^ ]+ / { if (pid != "") classify(); pid = $5; repo = $0; sub(/.* in /, "", repo); sub(/ .*/, "", repo); text = ""; started = 0; next }
       $5 != pid { next }
       / Starting new Claude session / { started = 1; next }
       started { line = $0; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ /, "", line); sub(/^[^ ]+ Claude error: /, "", line)
                 if (line !~ /^! / && substr(line, 1, 1) ~ /[ -~]/) text = text " " tolower(line) }
       END { if (pid != "") classify(); for (r in quits) print quits[r], r }' /tmp/quit-credfeto-YYYY-MM-DD.log

One known gap: a line of the agent's own message that starts with a marker character (an
agent sometimes writes "✓ ..." itself) is dropped as well, so a workaround phrase on such a
line is missed.

Each session's lines are joined into one lower-cased message and classified as a whole, the
same way the orchestrator does: a quit needs a denial mention, AND a session-level give-up
phrase, AND no workaround phrase once every negated workaround phrase ("nothing was pushed",
"not completed") has been removed, leftmost first, each replaced by a space. The four regexes
are TOOL_DENIAL_MENTION_PATTERNS, TOOL_DENIED_GIVE_UP_PATTERNS, TOOL_DENIED_WORKAROUND_PATTERNS
and TOOL_DENIED_NEGATED_WORKAROUND_PATTERNS from lib/globals, each joined with "|" and
lower-cased because the orchestrator matches them without regard to case.
lib/globals is the source of truth for the quit wording: if those patterns change, update these
to match. Report these counts in the summary as quit sessions found from the journal, per repo and date, and say that the
item numbers and denied command names are not available for that date. If the journal no
longer covers the date either (check the first timestamp in the file), say the date could not
be checked rather than reporting zero quits. The PRIVATE rule below applies in full to these
counts: they go to this summary and the private Discord channel only, never to GitHub.

A session is stalled when it quit believing a tool was denied or disabled (the quit column),
or when it hit denials and its PR made no progress. REPORT EVERY stalled or quit session in
this health check's own summary, with its repo, item, denial count and command names: a
denial that ended a session is a finding whatever the command, including those in the
by-design list below. The same sessions are alerted to the private Discord channel as
"Session stalled" (one per item per hour) and totalled in the "Daily session digest"; check
both reached that channel, and say so in the summary if the file shows a stalled session
with no matching alert.

PRIVATE: stalled and quit sessions belong in this summary and the private Discord channel
ONLY. NEVER post them, or any repository name, item number or command name taken from the
session-denials files, to GitHub: the tracking issues below are on a PUBLIC repository and
some of the repositories in these files are private.

Then the raw denial arrays, for gaps that did not end a session:

  grep -o '"permission_denials":\[[^]]*\]' /tmp/fleet.log | sort | uniq -c

Empty arrays are NOT findings. For non-empty ones from sessions that carried on, report ONLY
genuinely new gaps. Do not re-report anything already known to be blocked by design (this
exclusion never applies to a denial that ended a session; those are reported above):

  - git commands missing the `git -C <dir>` prefix
  - git worktree add
  - timeout, dotnet tool install, dotnet new tool-manifest
  - self-introspection into /opt or /workspace/rules after a denial (neither is in --add-dir)
  - `for` / `while` shell loop constructs
  - reads of ~/.claude (outside the trust boundary)
  - any read/cat/ls/grep/find of .database files
  - gh api user (deliberately excluded)
  - gh api graphql piped into python3 -c (known compound-pipe behaviour)

Post genuinely new findings from the raw arrays above (never a stalled or quit session,
see PRIVATE above) as comments on the standing tracking issues:
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
  - Never treat a stalled or quit session as "known by design"; it always goes in the report.
  - Never post a stalled or quit session (repo, item or command names) to any GitHub issue
    or PR; it goes in this summary and the private Discord channel only.
````

## Related

- #1361 — the incident this prompt was written in response to.
- #1342 / #1343 — the standing permission-denial tracking issues findings go to.
- [docs/agent-container.md](../docs/agent-container.md) — how the container is locked down.
- [docs/deployment-and-setup.md](../docs/deployment-and-setup.md) — how the services are installed.
