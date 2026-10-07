# How the agent container works

## The simplest possible explanation

When `oneshot` decides an Issue or Pull Request needs a turn of AI work, it doesn't run the AI
agent directly on the host machine. Instead it starts a brand-new, throwaway, locked-down
container — think of it like handing the agent a sealed room with only the tools and doors it's
allowed to use, that gets thrown away completely the moment the agent finishes its one turn. The
agent can read and write the specific repository checkout it's working on, and nothing else on
the host.

## Why a container, and why locked down this specifically

The agent runs under `--permission-mode dontAsk` (it doesn't stop to ask "can I run this
command?" before every tool call - there's no human present overnight to answer) against an
explicit `permissions.allow` list naming exactly the commands and tools the mandated workflow
uses, backed by `PreToolUse` hooks that enforce the same boundaries independently of Claude
Code's own permission system. Something has to make unattended operation safe. The container
is that something:

- It runs as an ordinary, unprivileged user (`developer`), not root.
- **Every tool that could install new software or escalate privilege is physically deleted from
  the image** — not merely restricted: `apt`, `apt-get`, `dpkg` and friends, plus `sudo`, `su`,
  `newgrp`, `sg`, `pkexec`. There is no path by which the agent could apt-install something new
  or become root, even if it tried.
- It only gets the specific host directories it needs, explicitly bind-mounted in: the target
  repository checkout (read/write), a read-only clone of shared linting rules, SSH/GPG access
  for signing commits, a small state directory for the agent's own session history, and a
  per-work-item directory for its conversation transcripts (see
  [Session transcripts](#session-transcripts)). Nothing else on the host filesystem is visible
  to it.
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

## Session transcripts

Claude Code writes each session's full conversation (every prompt, tool call and tool output) as
a JSONL file under `~/.claude/projects`. The image keeps `/home/developer/.claude` itself
root-owned so the agent cannot change its own settings, hooks or skills, which means `developer`
cannot create `projects` there; without a mount Claude Code silently runs without a transcript.
`oneshot` therefore bind-mounts a host directory onto `~/.claude/projects`, the same way it
mounts `sessions`, `session-env`, `plans`, `cache` and `backups`: podman creates the mountpoint
owned by the mapped `developer` uid, so only that one directory becomes writable.

Each work item gets its own host directory, so every session it ever runs accumulates in one
place:

```text
${XDG_STATE_HOME:-~/.local/state}/orchestrator/<owner>/<repo>/transcripts/Issue_<n>/
${XDG_STATE_HOME:-~/.local/state}/orchestrator/<owner>/<repo>/transcripts/PullRequest_<n>/
${XDG_STATE_HOME:-~/.local/state}/orchestrator/<owner>/<repo>/transcripts/_shared/
```

`_shared` is used by any launch without a work item, which in practice is `interactive`. The
directories are created mode `0700`: transcripts contain verbatim command text and output, and
nothing redacts them.

When an Issue pivots to its PR, `oneshot` makes `PullRequest_<m>` a relative symlink to
`Issue_<n>` (`link_pivot_pr_transcripts` in `lib/state`), so the PR's sessions are written into
the Issue's directory and the two share one history. `Issue_<n>` is the Issue in the
repository that the PR closes (its `closingIssuesReferences`, read from the PR state `oneshot`
has already fetched), not the Issue it was processing when it pivoted: the pivot takes the
repository's open bot PR, which need not belong to that Issue. A PR that closes more than one
Issue there is linked to the lowest-numbered of them; one that closes no Issue there is not
linked (an info message says so), and its sessions get a directory of their own.

The pivot counts as activity. It creates `Issue_<n>/` if needed and touches
`Issue_<n>/.orchestrator-last-pivot` (`TRANSCRIPT_PIVOT_ACTIVITY_FILE_NAME` in `lib/globals`), so
the prune that runs before the launch cannot purge an Issue that has been idle for 14 days and
leave the PR's sessions to start a directory of their own. The file is touched on every tick the
Issue pivots, whether or not a container launches, so an Issue whose PR is still open in the
priorities feed is kept for as long as that PR stays there. The file sits at the root of the
mounted `~/.claude/projects`, beside Claude Code's per-project subdirectories rather than inside
one. Then, for an existing `PullRequest_<m>` entry:

- a link, whether live or dangling, is left alone; a dangling link to the same Issue becomes live
  again because the Issue's directory has just been created;
- an empty real directory, left when the PR was processed directly from the feed before any
  pivot, or after an earlier purge of its Issue, is removed with `rmdir` and replaced by the
  link;
- a non-empty real directory is kept, so no transcript is lost, and an info message says so.

Every failure is a warning and never fails the run; the PR's sessions then get a directory of
their own.

Retention is by age, enforced before every container launch by `prune_transcripts`
(`lib/podman`). It does not depend on an item closing: a merged PR and the Issue it closes drop
out of the priorities feed, so `oneshot` almost never sees an item closed.

- An item's whole transcript directory is deleted once no file in it has been modified for
  14 days (`TRANSCRIPT_ITEM_RETENTION_DAYS` in `lib/globals`). Its age is the newest file
  modification time under it, found without following links; the directory's own modification
  time is not used, because appending to a transcript does not change it. A directory that
  contains no files is aged by its own modification time.
- A pivoted PR's link is never followed and is never deleted while its target exists. The PR's
  sessions write into the Issue's directory through it, so that directory stays fresh while the
  PR is being worked, and both go together once it has been idle for 14 days. A link whose
  target no longer exists is deleted (the link only, never anything through it), including one
  left dangling by the same pass.
- `_shared` is aged per session, inside each project directory Claude Code creates under
  `~/.claude/projects`. `interactive` always runs in `/workspace/repo`, so one project directory
  holds every session, and ageing it as a whole would let any recent session keep every older
  one forever. A session is `<session>.jsonl`, which every turn appends to, plus its side
  directory `<session>/` (tool results, subagents), whose files keep their original
  modification times. It is aged by the newest file of the session, across both, and both are
  deleted together once nothing in the session has been modified for 7 days
  (`TRANSCRIPT_RETENTION_DAYS`), so a resumed session keeps all of its side files. Any other
  entry in a project directory (a `<session>/` with no `.jsonl`, another file or directory) is
  aged on its own the same way. A project directory is deleted only once it is empty and its own
  modification time, read before its sessions are purged, is older than 7 days; a non-empty one
  is never deleted as a whole. A top-level file is aged by its own modification time, a
  top-level link follows the link rule above, and a link inside a project directory is never
  followed or deleted.

The purge never queries GitHub and never fails the run: a directory it cannot read or delete is
kept, with a warning, until the next launch. As a result, an item that is still open but has had
no session for 14 days loses its transcripts; that is acceptable because `oneshot` never resumes
a session, and the next session starts a fresh directory. The purge also only covers the
repository being launched for, so idle transcripts in a repository with no further launches wait
until that repository's next one. Unlike `podman image prune`, the purge also runs for
`interactive`: this is orchestrator state, not the developer's image store, and `_shared` would
otherwise grow forever.

`oneshot` still never resumes a session: every phase starts a fresh one, and the transcripts
exist so a human can read afterwards what an agent did and why.

## Interactive sessions

The `interactive` script starts this same container, with the same mounts, limits and baked-in permission settings, but attached to your terminal instead of running a single `--print` phase: you type, the agent works in the checkout containing your current directory (mounted at `/workspace/repo`), your host `cs-template` checkout is the read-only `/workspace/rules`, and scratch space is a fresh directory under `$XDG_RUNTIME_DIR` mounted at `/workspace/tmp`. The Claude state directories `oneshot` mounts (`sessions`, `session-env`, `plans`, `cache`, `backups`) are shared under `${XDG_STATE_HOME:-~/.local/state}/orchestrator/<owner>/<repo>/claude`, and conversation transcripts (`~/.claude/projects`) are kept alongside it in `<owner>/<repo>/transcripts/_shared`, so `/resume` and `claude --continue` in a later launch find any session modified in the last 7 days (see [Session transcripts](#session-transcripts)). Everything the entrypoint checks above still applies, and `interactive` runs the same refusals on the host first, before the image pull, naming host paths: a linked worktree or submodule, an origin that is not a `git@github.com:` SSH URL (`oneshot` rewrites its own clones' remotes; `interactive` never rewrites yours), a checkout that is or contains `$HOME`, or a `.claude/settings.json`, `.claude/settings.local.json` or `.mcp.json` that differs from `origin/main`. Podman secrets are named after the container (`interactive-<owner>-<repo>` rather than `orchestrator-<owner>`) so a session alongside a running `oneshot` timer on the same host can never delete the secret that run is about to consume, and dangling images are never pruned from a developer's own store. The generated CLAUDE.md is different: instead of the one-phase-per-session issue/PR steps it carries the owner's own working rules (approval words, assumptions first, standing commit/push authorisation), rewritten for the container's paths.

The trust model is different too. `oneshot` runs under a dedicated service account; `interactive` runs as you, so the container is handed your SSH agent (every loaded key), your GPG agent's extra socket, your Claude OAuth token for the owner, your `gh` token, your `~/.database` credentials file read-only when it exists (for `querydb`, as for `oneshot`), and the checkout read-write, including `.git/config` and `.git/hooks`, which git on the host executes the next time you run it in that checkout. `interactive` digests both before the session and warns afterwards if either changed; the permission settings and hooks are the same as `oneshot`'s, but the credentials behind them are personal.

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
