<!-- Locally Maintained -->
# Debugging Instructions

[Back to Local Instructions Index](index.md)

> Load when: investigating orchestrator misbehaviour, diagnosing a stalled or skipped work item, or any time you need to understand the live state of the running orchestrator before making changes.

## Before Debugging — SSH to nanoclaw.lan

Always connect to `markr@nanoclaw.lan` and review the live state **before** drawing conclusions or making changes. The machine is where the orchestrator runs; local repo state alone is insufficient.

```bash
ssh markr@nanoclaw.lan
```

## State Inventory

### 1 — Orchestrator version

```bash
git -C ~/work/personal/credfeto-orchestrator rev-parse --short HEAD
git -C ~/work/personal/credfeto-orchestrator status
```

Confirms which version of `oneshot`/`loop` is deployed. A dirty tree or a commit behind `origin/main` is often the root cause of unexpected behaviour because `loop` pulls before every iteration.

### 2 — Loop service

```bash
systemctl --user status orchestrator-loop.service 2>/dev/null \
    || systemctl status orchestrator-loop.service 2>/dev/null \
    || ps aux | grep '[l]oop'
```

Determines whether the loop is running, stopped, or failed. Check `journalctl --user -u orchestrator-loop.service -n 50` (or without `--user`) for recent output.

### 3 — Lock files

```bash
ls -la ~/.orchestrator/locks/
```

A stale lock (`_global.lock` or `<owner>.lock`) left by a crashed process will cause every subsequent `oneshot` run to exit immediately with "Another oneshot instance is already running". Verify with `flock --exclusive --nonblock <lockfile>` — if it fails to acquire, a process still holds it; if it succeeds, the lock is stale and safe to remove.

### 4 — Rate-limit files

```bash
find ~/.orchestrator -name 'rate-limit' -exec echo {} \; -exec cat {} \;
```

A rate-limit file contains a unix timestamp. Compare against `date +%s` — if the stored value is in the future, the orchestrator will skip all items for that owner until it expires.

### 5 — Session files

```bash
find ~/.orchestrator -name '*.env' | sort
```

Each file holds a Claude session ID for one Issue or PullRequest. An invalid, expired, or missing session ID causes `invoke_claude` to fall back to a fresh session (expected) or die (unexpected). Read the file to confirm the format is a valid UUID:

```bash
cat ~/.orchestrator/<owner>/<repo>/Issue_<n>.env
```

### 6 — Fingerprint files

```bash
find ~/.orchestrator -name '*.fingerprint' | sort
find ~/.orchestrator -name '*.fingerprint' -exec echo "=== {} ===" \; -exec cat {} \;
```

A fingerprint file holds the SHA-256 hash of a PR's or Issue's state at the end of the last run. When the fingerprint matches the current GitHub state, `oneshot` skips the item. An incorrect or stale fingerprint is why an item that should be worked on is being skipped.

To force a re-run, delete the relevant fingerprint file:

```bash
rm ~/.orchestrator/<owner>/<repo>/PullRequest_<n>.fingerprint
rm ~/.orchestrator/<owner>/<repo>/Issue_<n>.fingerprint
```

### 7 — Docker containers

```bash
sudo docker ps -a --filter 'name=orchestrator'
```

A container named `orchestrator-<owner>` left running (or in exited state with `--rm` not honoured) will cause the next `invoke_claude` call to die with "Container already exists". Remove it manually:

```bash
sudo docker rm -f orchestrator-<owner>
```

Also check for containers stuck in an unexpected state:

```bash
sudo docker ps -a
```

### 8 — Working directories

```bash
for d in ~/work/*/*/repo; do
    echo "=== $d ==="
    git -C "$d" status --short
    git -C "$d" branch --show-current
done
```

A dirty working tree or a non-main branch left from a previous session is detected by `ensure_repo_current` and handed to the agent as `DIRTY_BRANCH`. Confirm whether uncommitted changes are expected or residue from a crash.

### 9 — Config and tokens

```bash
ls -la ~/.config/orchestrator/
cat ~/.config/orchestrator/.env   # shows DISCORD_WEBHOOK= and GH_HOST= lines; tokens are redacted in logs
ls -la ~/.config/orchestrator/tokens/
```

Missing or malformed config causes Discord notifications to silently fail and GH Enterprise calls to fall through to the wrong host.

### 10 — Priorities API

```bash
curl --silent --fail https://git-workflow.markridgwell.com/priorities | jq '.'
```

Confirms whether the priorities API is reachable and returning valid JSON. An empty or malformed response will cause `oneshot` to exit early.

## Interpreting Common Symptoms

| Symptom | Most likely cause | Where to look |
| --- | --- | --- |
| `oneshot` exits immediately silently | Stale lock file | Section 3 |
| Item skipped every run despite changes | Fingerprint not updating | Section 6 |
| All items skipped for an owner | Rate-limit file active | Section 4 |
| `invoke_claude` dies "container exists" | Previous container not removed | Section 7 |
| Agent starts from scratch every run | Session file missing or UUID invalid | Section 5 |
| No Discord notifications | `DISCORD_WEBHOOK` not set in `.env` | Section 9 |
| Priorities fetch fails | API unreachable or auth issue | Section 10 |
| `oneshot` running old logic | Repo behind `origin/main` | Section 1 |

## After Reviewing State

Summarise what you found before proposing any fix:

- Which state files are present, and what they contain
- Whether any containers are running or stale
- Whether the lock is held
- The current git state of the orchestrator repo itself

Only then proceed with a diagnosis or change.
