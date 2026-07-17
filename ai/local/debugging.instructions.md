<!-- Locally Maintained -->
# Debugging Instructions

[Back to Local Instructions Index](index.md)

> Load when: investigating orchestrator misbehaviour, diagnosing a stalled or skipped work item, or any time you need to understand the live state of the running orchestrator before making changes.

## Headless Operation Principle (MANDATORY)

The orchestrator is designed to run **completely unattended**.  Any condition that requires a human to intervene — deleting a file, resetting a branch, restarting a service, running a manual command — is a **bug** and must be fixed in code so the orchestrator recovers automatically on the next run.

**Never ask the user to perform a manual recovery step.**  If you identify a problem, either fix it in the orchestrator's code, or (while the fix is being developed) perform the recovery yourself via SSH.

## Before Debugging — SSH to nanoclaw.lan (MANDATORY)

When asked to diagnose a problem with the orchestrator, or when something is behaving unexpectedly, **you must SSH to `markr@nanoclaw.lan` and inspect the live state yourself.**  Do not ask the user to run commands or collect information — go and look yourself.

```bash
ssh markr@nanoclaw.lan
```

Run the relevant commands from the State Inventory below, interpret the output, and report your findings.  Only after you have done this should you propose a fix or ask the user a question.

## Real Deployment Layout (verified against `setup-owner`/`install-timer`, #1185 review)

Production runs each configured owner (e.g. `credfeto`, `funfair-tech`) as its **own separate
Linux user account** with its own home directory, its own checkout, and its own systemd
service/timer pair — there is no single shared orchestrator checkout or service. `markr`'s own
home directory is a personal interactive-dev checkout only; it is **not** one of the live
service accounts, and its checkout being behind `origin/main` is expected (nothing auto-updates
it) rather than a symptom of anything broken.

- **Checkout path**: `/home/<owner>/credfeto-orchestrator` (from `setup-owner`'s
  `clone_or_pull_repo`: `clone_dir="${owner_home}/credfeto-orchestrator"`) — **not**
  `~/work/personal/credfeto-orchestrator`.
- **State/config paths**: `/home/<owner>/.orchestrator/...` and `/home/<owner>/.config/orchestrator/...`,
  matching every `~/.orchestrator`/`~/.config/orchestrator` path below — but read as "the owner's
  home", not `markr`'s.
- **Systemd unit names**: `credfeto-orchestrator-<owner>-<owner>.service` and `.timer` (from
  `install-timer`'s `SERVICE_NAME="credfeto-orchestrator-${CURRENT_USER}-${owner_filter}"`, and
  `CURRENT_USER` is normally the owner account itself, hence the doubled name) — **not**
  `orchestrator-loop.service`. These are system-level units (`sudo systemctl status <name>`, no
  `--user`), not user units.
- **Inspecting another owner's checkout as `markr`**: their home directory is typically only
  readable via `sudo`, and `git` will refuse with "detected dubious ownership" if you `sudo git -C`
  a directory owned by a different user. Use a scoped override rather than a persistent global
  config change: `sudo git -c safe.directory=/home/<owner>/credfeto-orchestrator -C /home/<owner>/credfeto-orchestrator status`.
  Prefer this over `sudo -u <owner> git ...` — some sessions have a permission rule that denies
  `sudo -u` specifically (routing a sudo invocation through a different effective user is treated
  as more sensitive than running a read-only command as root).

## Always Read the Full GitHub Timeline, Not Just Current State (MANDATORY)

When investigating any Issue or PR, pull its full timeline — not just its current labels/state via `gh pr view`/`gh issue view`:

```bash
gh api repos/<owner>/<repo>/issues/<n>/timeline --paginate -q '.[] | select(.event=="labeled" or .event=="unlabeled" or .event=="reviewed" or .event=="committed" or .event=="head_ref_force_pushed") | [.event, (.label.name // .state // .sha // ""), .created_at, .actor?.login] | @tsv'
```

Current state alone is a snapshot and hides *when* things happened and *what didn't happen in between* — exactly the evidence that matters for "why did this get stuck". For example, PR #116 in `credfeto-enum-source-generation` looked like an ordinary blocked PR from its current state; only the timeline revealed that a human removed the `Blocked` label and approved it, and the bot re-added `Blocked` under two hours later with **zero** commits, reviews, or force-pushes in between — proving the automation never even got a turn, rather than that it failed to resolve something (see #1115).

## State Inventory

### 1 — Orchestrator version

Run per owner (see Real Deployment Layout above for why the path/sudo form is needed):

```bash
sudo git -c safe.directory=/home/<owner>/credfeto-orchestrator -C /home/<owner>/credfeto-orchestrator rev-parse --short HEAD
sudo git -c safe.directory=/home/<owner>/credfeto-orchestrator -C /home/<owner>/credfeto-orchestrator status
```

Confirms which version of `oneshot`/`lib/*` is deployed for that owner. This checkout self-updates via the systemd unit's own `ExecStartPre` (`git fetch` + `merge --ff-only origin/main`) immediately before every run, not via `loop`'s self-update path — a dirty tree or a commit behind `origin/main` right after a service run means that `ExecStartPre` step itself failed; check the service's own log (Section 2) for the exact fetch/merge error.

### 2 — Orchestrator service

```bash
sudo systemctl status "credfeto-orchestrator-<owner>-<owner>.service" --no-pager -l
sudo systemctl list-timers "credfeto-orchestrator-<owner>-*" --no-pager
```

Determines whether the service is running (`activating` for the duration of one `oneshot` cycle — normal, not stuck, if the cgroup process tree is still actively computing), idle between ticks (`inactive (dead)`, exited 0), or failed. Check `sudo journalctl -u "credfeto-orchestrator-<owner>-<owner>.service" -n 100 --no-pager` for recent output, including the `ExecStartPre` fetch/merge/agent-setup steps.

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

### 5 — PR invocation-guard files

The orchestrator no longer persists Claude session IDs — every run is a fresh single-phase
session (see `oneshot-prompts.instructions.md`). Instead each PR has an invocation-guard file
holding two space-separated counters, `<total> <idle>`:

```bash
find ~/.orchestrator -name 'PullRequest_*.invocations' | sort
find ~/.orchestrator -name 'PullRequest_*.invocations' -exec echo "=== {} ===" \; -exec cat {} \;
```

- `total` — every agent invocation ever spent on the PR. At `MAX_PR_TOTAL_INVOCATIONS` (default 30) the PR is marked Blocked. A PR stuck at a high total that never merges is churning without converging.
- `idle` — consecutive re-invocations where the PR fingerprint did not change (a phase that advanced the board without pushing). At `MAX_PR_IDLE_INVOCATIONS` (default 5) the PR is parked (skipped) until its state changes. A PR parked here is either done and waiting on a human, or a phase failed to leave a durable trace.

A companion `PullRequest_<n>.runaway-blocked` (or `Issue_<n>.runaway-blocked`) marker file records that this item was observed `Blocked` while its total already sat at/over the cap — written both by oneshot's own runaway backstop *and*, since #1115, whenever oneshot observes the item blocked by any other mechanism (the code-review workflow's own rules, CI-timeout, idle-exhaustion, a manual label) while already capped. When a human clears the `Blocked` label, oneshot only resets `total`/`idle` to `0` if this marker is present — so a human-driven unblock on a capped item reliably gets a fresh invocation budget regardless of which rule applied the block. If a capped PR/Issue was re-blocked instantly after a human cleared it with no new agent activity in between (check the GitHub timeline — see above), first confirm the marker was written on the observing tick; its absence points to a gap in marker coverage, not user error.

Delete the file to reset both counters (also makes the next run treat the PR as first-touch and re-initialise its board status to "Not Started"):

```bash
rm ~/.orchestrator/<owner>/<repo>/PullRequest_<n>.invocations
```

### 5a — Environment auto-unblock files (#1118)

When an agent diagnoses a `Blocked`-ing failure as environmental/infrastructure (e.g. a missing tool in the container), it leaves a machine-readable trailer on its diagnosis comment: `<!-- orchestrator:env-block image-sha=<sha> -->` (see `agent-roles.instructions.md` § "Environment/Infrastructure Block Marker"). `oneshot` checks every `Blocked` PR carrying this marker against the currently-pulled agent image's own baked-in `IMAGE_SHA_DEVELOPMENT_AGENT` — if a newer image has been built since the diagnosis (different SHA), it auto-clears `Blocked` and comments, with no human needed:

```bash
find ~/.orchestrator -name 'PullRequest_*.env-unblocks' -exec echo "=== {} ===" \; -exec cat {} \;
find ~/.orchestrator -name 'PullRequest_*.env-unblock-cap-notified'
```

- `PullRequest_<n>.env-unblocks` — count of times oneshot has auto-cleared this PR's Blocked label for an environment diagnosis. Resets to nothing whenever the PR is next observed open-and-unblocked through the normal path (a human clearing it, or a fresh unrelated block cycle).
- At `MAX_PR_ENV_AUTO_UNBLOCKS` (default 3), oneshot stops auto-clearing and instead posts a one-time comment saying the same failure recurred after a rebuild (the "environment" diagnosis was likely wrong) — `PullRequest_<n>.env-unblock-cap-notified` marks that this notice has already been sent, so it isn't repeated every tick.
- If a PR you expected to auto-unblock is still sitting `Blocked`, check (a) whether its latest diagnosis comment actually carries the marker, (b) whether `current_agent_image_sha` (a `podman inspect` on `${ORCHESTRATOR_IMAGE}`) actually differs from the recorded SHA — the image may not have rebuilt yet — and (c) whether the `.env-unblock-cap-notified` marker is already present (the cap was hit).

### 6 — Fingerprint files

```bash
find ~/.orchestrator -name '*.fingerprint' | sort
find ~/.orchestrator -name '*.fingerprint' -exec echo "=== {} ===" \; -exec cat {} \;
```

A fingerprint file holds `<schema-version>:<SHA-256 hash>` of a PR's or Issue's state at the end of the last run (see [fingerprinting.instructions.md](fingerprinting.instructions.md) for what's hashed and why the version prefix exists). When the fingerprint matches the current GitHub state, `oneshot` skips the item. An incorrect or stale fingerprint is why an item that should be worked on is being skipped — including a plan approved purely on the Workflow board, which the fingerprint now accounts for (#1204); if a board-approved item is still stuck, check whether `FINGERPRINT_SCHEMA_VERSION` was bumped for whatever field is supposed to catch it.

To force a re-run, delete the relevant fingerprint file:

```bash
rm ~/.orchestrator/<owner>/<repo>/PullRequest_<n>.fingerprint
rm ~/.orchestrator/<owner>/<repo>/Issue_<n>.fingerprint
```

### 7 — Podman containers

Containers run as **rootless Podman** under the owner's own user namespace (Docker was replaced
with rootless Podman; `docker` is not installed on the host at all, so `sudo docker ...` fails
with "command not found", not a permission error). `sudo podman ps` from `markr` shows root's own
(empty) rootless namespace, not the owner's — it does **not** reveal the owner's containers. The
practical way to confirm a container is genuinely running (vs. hung) as `markr` is to read the
process tree directly, which doesn't require entering the owner's podman namespace:

```bash
sudo systemctl status "credfeto-orchestrator-<owner>-<owner>.service" --no-pager -l
```

The `CGroup:` section lists the live process tree, including the `podman run --name
orchestrator-<owner> ...` invocation and, once started, the container's own `claude` process and
any build/test tooling it spawned — if those PIDs are actively accumulating CPU time across
repeated checks, the container is working, not stuck. A container named `orchestrator-<owner>`
left running (or in exited state with `--rm` not honoured) will cause the next `invoke_claude`
call to die with "Container already exists"; if the service log confirms this, become that owner
to remove it (`sudo -iu <owner>` if your session allows `sudo -u`-style commands, otherwise ask a
human with owner access) with `podman rm -f orchestrator-<owner>`.

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
| Agent starts from scratch every run | Expected — every run is a fresh single-phase session (no resume) | Section 5 |
| PR worked repeatedly then Blocked, or parked mid-workflow | `total`/`idle` invocation-guard caps reached | Section 5 |
| No Discord notifications | `DISCORD_WEBHOOK` not set in `.env` | Section 9 |
| Priorities fetch fails | API unreachable or auth issue | Section 10 |
| `oneshot` running old logic | Repo behind `origin/main` | Section 1 |
| `Workflow project: ... status updates disabled` + a `Workflow project setup required` issue in the repo | No `Workflow` project for the repo; the bot cannot create one under a personal account | Run `create-project --repo <owner>/<repo>` as the repo owner |
| `Workflow` project exists (visible by node ID) but `oneshot` always treats the repo as having no project | Repo has `hasProjectsEnabled: false`; `repository.projectsV2` returns empty even when the project is linked | `gh repo edit <owner>/<repo> --enable-projects`, then re-run `create-project` |
| `newuidmap: Could not set caps` / `cannot set up namespace using "/usr/bin/newuidmap"`; container pull/start fails | Service unit drops the caps rootless Podman needs (`CapabilityBoundingSet=` empty and/or `NoNewPrivileges=yes`), so `newuidmap`/`newgidmap` cannot map subuid/subgid ranges | Unit must set `NoNewPrivileges=no` and `CapabilityBoundingSet=CAP_SETUID CAP_SETGID` (see `install-timer`); re-run `install-timer` to regenerate, or apply a drop-in override as interim recovery |
| Image pull fails with `creating a temporary directory: mkdir /var/tmp/container_images_storage…: no such file or directory` (often only when the image actually needs a fresh layer copy) | Service unit sets `PrivateTmp=yes`; rootless Podman's persistent pause process captured the empty private `/var/tmp`, so all later pulls in that pause namespace see a broken `/var/tmp` | Drop `PrivateTmp` from the unit (see `install-timer`); to recover a live host, clear the pause process (`pkill -u <owner> -f catatonit; pkill -u <owner> -f 'podman pause'`) and regenerate/override the unit so the next run does not re-leak |

## After Reviewing State

Summarise what you found, then act:

- Which state files are present, and what they contain
- Whether any containers are running or stale
- Whether the lock is held
- The current git state of the orchestrator repo itself

If the problem required any manual action to resolve (deleting a file, resetting a branch, removing a container), **that manual action is a bug**.  Fix it in the orchestrator's code so it cannot recur — raise a GitHub issue if a code fix is non-trivial.
