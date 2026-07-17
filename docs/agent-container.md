# How the agent container works

## The simplest possible explanation

When `oneshot` decides an Issue or Pull Request needs a turn of AI work, it doesn't run the AI
agent directly on the host machine. Instead it starts a brand-new, throwaway, locked-down
container — think of it like handing the agent a sealed room with only the tools and doors it's
allowed to use, that gets thrown away completely the moment the agent finishes its one turn. The
agent can read and write the specific repository checkout it's working on, and nothing else on
the host.

## Why a container, and why locked down this specifically

The agent is given `--dangerously-skip-permissions` (it doesn't ask "can I run this command?"
before every tool call) so it can work unattended overnight. Something has to make that safe.
The container is that something:

- It runs as an ordinary, unprivileged user (`developer`), not root.
- **Every tool that could install new software or escalate privilege is physically deleted from
  the image** — not merely restricted: `apt`, `apt-get`, `dpkg` and friends, plus `sudo`, `su`,
  `newgrp`, `sg`, `pkexec`. There is no path by which the agent could apt-install something new
  or become root, even if it tried.
- It only gets the specific host directories it needs, explicitly bind-mounted in: the target
  repository checkout (read/write), a read-only clone of shared linting rules, SSH/GPG access
  for signing commits, and a small state directory for the agent's own session history. Nothing
  else on the host filesystem is visible to it.
- The container is destroyed (`--rm`) the instant the session ends — a fresh container, with a
  fresh session, for every single invocation. Nothing an agent does inside one session can
  persist into the next except via the state directories explicitly listed above, or (the whole
  point) commits it actually pushed to GitHub.

## What's actually running inside it

The image is `ghcr.io/credfeto/development-agent`, itself built on top of a long chain of other
images (see [base-image-chain.md](base-image-chain.md)) that provide the .NET SDK, Node, Python,
and every linting/CI tool the agent might need to build and test a change before committing it.
On top of all of that, this final image:

1. Deletes the package-management/privilege-escalation binaries listed above.
2. Adds a small `agent-entrypoint` script (see below) as the container's `ENTRYPOINT`.
3. Creates the two mount points the workspace needs: `/workspace/repo` and `/workspace/rules`.
4. Bakes GitHub's SSH host key into the system-wide `known_hosts` at build time, so the running
   container never needs to make a network call just to learn who it's talking to.
5. Runs a long build-time sanity check that fails the whole image build if any expected tool
   is missing, any removed tool is somehow still reachable, or the entrypoint itself is broken —
   catching a broken image at build time, not three hours into an unattended overnight run.

## What the entrypoint checks before the agent ever starts

Every single container start runs through a chain of pre-flight checks (`entrypoint.sh`) before
`claude` itself is even executed. Any one of these failing means the container exits immediately
with a clear error, and `oneshot` treats that as "the environment/infrastructure was broken,"
not "the agent failed at its task" (see the `invoke_claude`/`run_claude_fresh` distinction in
[oneshot.md](oneshot.md) — this is exactly why that distinction exists):

- The required environment variables are actually set (an OAuth token, git identity, a signing
  key) — no silent "works by accident" fallback.
- GPG signing actually works end-to-end: the agent, the key, and a real test signature.
- SSH signing/push access to GitHub actually works end-to-end, with a clear, specific error for
  each distinct way it could fail (no agent running at all, no keys loaded, the key not
  registered with GitHub, too many keys offered).
- The repository checkout's git remote is genuinely `git@github.com:...` (SSH), never rewritten
  to something else.
- The repository checkout carries no local `[url insteadOf]` rewrite rules — those are only
  permitted in the container's own system-wide git config, never something a PR branch could
  have smuggled in.
- **The repository checkout carries no `.claude/settings.json`, `.claude/settings.local.json`,
  or `.mcp.json` that differs from the reviewed copy already on `origin/main`.** This is a real
  security boundary, not a formality: Claude Code auto-loads and *runs* hooks and MCP server
  definitions from a trusted project the moment it's trusted, and this container pre-accepts
  that trust automatically (since there's no human present to click "trust this project" on a
  fresh, unattended container). If a Pull Request branch could smuggle in its own
  `.claude/settings.json`, checking it out would let that branch's content silently execute
  arbitrary commands the instant the container started. Comparing the exact file bytes (not just
  "does a file with this name exist") against what's already reviewed and merged closes that
  hole.

Only once every one of these passes does the entrypoint exec `claude` itself, handing it the
prompt built by `oneshot` (see [oneshot.md](oneshot.md) and
[workflow-board.md](workflow-board.md) for what that prompt actually contains).

## Assumptions

- The host has already loaded a usable SSH key (via `ssh-agent`) and GPG signing key before
  `oneshot` ever tries to start a container — the entrypoint's checks exist to catch a *broken*
  setup fast and clearly, not to set one up from nothing.
- The image is rebuilt and re-pulled often enough that a fixed baked-in GitHub SSH host key
  doesn't itself become stale in a way that matters (GitHub host key rotations are rare and
  widely announced events).
- Removing package-management/privilege-escalation tools from the image is a one-way ratchet:
  getting them back requires a full image rebuild, not something reachable from inside a running
  container.
