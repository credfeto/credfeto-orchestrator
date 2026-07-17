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
| `setup-owner` | Provisions a new Linux system user for an owner: creates the account, clones this repository into its home directory, and sets up the directories `oneshot` expects to find (state, config, tokens). Idempotent — safe to re-run; already-done steps are skipped. |
| `install-timer` | Installs a systemd **system-level** service and timer (not a user unit — it must keep running even when nobody is logged in) that runs `oneshot` on a fixed interval as the current user, with a startup timeout so a single network hang can never silently stop the timer from ever firing again. |
| `uninstall-timer` | Reverses `install-timer` — stops and removes the systemd service/timer. |
| `create-project` | Provisions the "Workflow" GitHub Project (v2) board for a specific repository (see [workflow-board.md](workflow-board.md)) — must be run by the repository owner personally, since a bot account cannot create a Project under a personal GitHub account. Idempotent; seeds the board with every existing open Issue/PR only on first creation. |
| `install-claude-hooks` | Installs the agent container's baked-in Claude Code settings and hooks onto the *host* user's own `~/.claude`, so the same guardrail hooks (e.g. the ones that block dangerous git commands) can be exercised interactively outside the container too. |

## Onboarding a new owner, roughly in order

1. Run `setup-owner --owner <name>` to create the Linux account and checkout.
2. Configure that owner's credentials (a Claude OAuth token, GitHub token, git identity/signing
   key) in its own config directory.
3. Run `install-timer` as that owner, so `oneshot` starts running automatically on its own
   schedule.
4. For each repository that owner works on: run `create-project --repo <owner>/<repo>` once, as
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
