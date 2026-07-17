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
| `setup-owner` | Provisions a new Linux system user for an owner: creates the account, clones this repository into its home directory, copies in the credentials staged by the invoking admin (see below), and — as its very last step — runs `install-timer` on the new owner's behalf. Idempotent — safe to re-run; already-done steps are skipped. |
| `install-timer` | Installs a systemd **system-level** service and timer (not a user unit — it must keep running even when nobody is logged in) that runs `oneshot` on a fixed interval as the current user, with a startup timeout so a single network hang can never silently stop the timer from ever firing again. Normally invoked automatically by `setup-owner`; only needs to be run by hand to change the timer's own settings (e.g. its interval) after the fact. |
| `uninstall-timer` | Reverses `install-timer` — stops and removes the systemd service/timer. |
| `create-project` | Provisions the "Workflow" GitHub Project (v2) board for a specific repository (see [workflow-board.md](workflow-board.md)) — must be run by the repository owner personally, since a bot account cannot create a Project under a personal GitHub account. Idempotent; seeds the board with every existing open Issue/PR only on first creation. |
| `install-claude-hooks` | Installs `development-full`'s baked-in Claude Code settings and hooks onto the *host* user's own `~/.claude`, so the same guardrail hooks (e.g. the ones that block dangerous git commands) can be exercised interactively outside a container too. |

## Onboarding a new owner, roughly in order

1. **Before running anything as the new owner**: stage that owner's credentials in the
   *invoking admin's own* config directory — `setup-owner` copies them from here, it does not
   collect them interactively. This means, as the admin: `gh auth login`, a
   `~/.config/orchestrator/.env` with `GIT_USER_NAME`/`GIT_USER_EMAIL`/`GIT_SIGNING_KEY`/
   `DISCORD_WEBHOOK`, and a `~/.config/orchestrator/tokens/<owner-name>` file (mode `600`)
   holding that owner's Claude OAuth token. `setup-owner` refuses to proceed at all — before
   touching the system — if any of these are missing.
2. Run `setup-owner --owner <name>`. This creates the Linux account, clones the repository into
   it, copies the staged credentials in, **and installs the timer itself** — there is no separate
   manual "now run install-timer" step for a first-time setup.
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
