# How deployment and setup work

## The simplest possible explanation

The orchestrator doesn't run as one single shared program watching every repository. Instead,
each GitHub account it works on behalf of (an "owner" — e.g. `credfeto`, `funfair-tech`) gets its
own completely separate Linux user account on the host machine, with its own checkout of this
repository and its own timer that runs `oneshot --owner <that-owner>` on a fixed schedule. This
document covers the scripts that set all of that up.

## The scripts, and what each one does

| Script | What it does |
| --- | --- |
| `setup-owner` | Run as root (e.g. `sudo ./setup-owner --owner <name>`). Provisions a new Linux system user for an owner: creates the account, clones this repository into its home directory, copies in the credentials staged by the invoking admin (see below), and — as its very last step — installs a systemd **system-level** service and timer (not a user unit — it must keep running even when nobody is logged in) via `lib/systemd-units`, which runs `oneshot --owner <name>` on a fixed interval as the owner, with a startup timeout so a single network hang can never silently stop the timer from ever firing again. Re-run it to change the timer's settings (e.g. `ORCHESTRATOR_TIMER_INTERVAL`). Idempotent — safe to re-run; already-done steps are skipped. |
| `teardown-owner` | Run as root. Reverses the unit installation for an owner: stops and disables the timer, then removes the systemd service, timer and failure units and the owner's polkit rule. Leaves the user account, home directory and checkout in place. |
| `create-project` | Provisions the "Workflow" GitHub Project (v2) board for a specific repository (see [workflow-board.md](workflow-board.md)) — must be run by the repository owner personally, since a bot account cannot create a Project under a personal GitHub account. Idempotent; seeds the board with every existing open Issue/PR only on first creation. |
| `install-claude-hooks` | Installs `development-full`'s baked-in Claude Code settings and hooks onto the *host* user's own `~/.claude`, so the same guardrail hooks (e.g. the ones that block dangerous git commands) can be exercised interactively outside a container too. Also installs the `cfwf` workflow helper into `/usr/local/bin` (via `sudo` if needed) and refuses to run if a tool the hooks depend on is missing. |

## Onboarding a new owner, roughly in order

1. **Before running anything as the new owner**: stage that owner's credentials in the
   *invoking admin's own* config directory — `setup-owner` copies them from here, it does not
   collect them interactively. This means, as the admin: `gh auth login`, a
   `~/.config/orchestrator/.env` with `GIT_USER_NAME`/`GIT_USER_EMAIL`/`GIT_SIGNING_KEY`/
   `DISCORD_WEBHOOK`, and a `~/.config/orchestrator/tokens/<owner-name>` file (mode `600`)
   holding that owner's Claude OAuth token. `setup-owner` refuses to proceed at all — before
   touching the system — if any of these are missing. `.env` can optionally also set
   `DISCORD_WEBHOOK_BLOCKED`/`DISCORD_WEBHOOK_AWAITING_APPROVAL`/`DISCORD_WEBHOOK_PERMISSIONS`/
   `DISCORD_WEBHOOK_SLOW_PULL` to route those specific alert categories to their own webhook
   instead of `DISCORD_WEBHOOK` — see [discord-notifications.md](discord-notifications.md);
   `setup-owner` does not require any of these four.
2. Run `sudo ./setup-owner --owner <name>`. This creates the Linux account, clones the
   repository into it, copies the staged credentials in, **and installs the timer itself** —
   there is no separate timer-install step.
3. For each repository that owner works on: run `create-project --repo <owner>/<repo>` once, as
   the human repository owner (not the bot), so the Workflow board (and its plan-approval gate)
   exists before the orchestrator starts picking up real work there. A repository without a
   board still works — see [workflow-board.md](workflow-board.md) for the comment-based
   fallback — but loses the visible one-column approval gate.

## Assumptions

- Every script here is safe to re-run: whatever's already correctly set up is detected and
  skipped, so re-running after a partial failure (or just to pick up a config change) never
  duplicates or corrupts existing state.
- `systemd` (with system-level, not user-level, units) is the process supervisor on the host —
  nothing here supports a different init system.
- Only the actual repository owner's own GitHub credentials can create a Project under their
  personal account; the bot account is expected to have write access to an *existing* project
  (granted by `create-project`), never to create one itself.
