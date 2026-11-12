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
Code's own permission system. Raw `gh` is not on that list: it is denied outright (`Bash(gh)` and
`Bash(gh *)` in `permissions.deny`, and `gh` on the hooks' `command-blocklist`), and a refused call
says ``gh is not permitted - raw gh is not available to agents; use cfwf (run `cfwf help`)``.
Every GitHub operation goes through `cfwf` or its MCP server; `cfwf` runs `gh` itself, as a
subprocess the agent's permission rules do not see (#1805). Something has to make unattended
operation safe. The container is that something:

- It runs as an ordinary, unprivileged user (`developer`), not root.
- **Every tool that could install new software or escalate privilege is physically deleted from
  the image** — not merely restricted: `apt`, `apt-get`, `dpkg` and friends, plus `sudo`, `su`,
  `newgrp`, `sg`, `pkexec`. There is no path by which the agent could apt-install something new
  or become root, even if it tried.
- It only gets the specific host directories it needs, explicitly bind-mounted in: the target
  repository checkout (read/write), a read-only clone of shared linting rules, SSH/GPG access
  for signing commits, a small state directory for the agent's own session history, a
  per-work-item directory for its conversation transcripts (see
  [Session transcripts](#session-transcripts)), and a per-work-item directory for its CodeGraph
  index (see [The CodeGraph index](#the-codegraph-index)). Nothing else on the host filesystem is
  visible to it.
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

Claude Code can reach only the MCP servers pinned by `development-full` in a root-owned
`/etc/claude-code/managed-mcp.json`, so the agent cannot add a server or point one anywhere else. The
image requires four:

- `cfwf`, the workflow MCP server at `https://workflow-mcp.markridgwell.com/mcp`. The file holds
  no token. A root-owned helper hands Claude Code's MCP client the GitHub token the container
  already has, at connect time, so the token is never written to the image or to disk. Nothing
  routes work to the server yet.
- `kb`, the knowledge-base MCP server at `https://memory.markridgwell.com/dev/mcp`. Its token is
  the optional `KB_MCP_TOKEN` in `orchestrator/.env`, which `oneshot` passes in as a per-container
  Podman secret and removes on exit; a root-owned helper hands it to the MCP client at connect
  time. Without it, the session starts with `kb` shown as failed to connect. A malformed value (one
  holding a character a bearer token cannot contain) is ignored with a warning that never prints it.
- `build-dotnet`, the .NET build, test and coverage server (`credfeto-build-dotnet`, a local stdio
  process), working on the repository at `/workspace/repo` (#1818). It is registered for every
  session, whatever the repository's language.
- `codegraph`, the code knowledge graph server (`codegraph serve --mcp`, a local stdio process).
  In a repository with no `.codegraph/` index its tools answer that the project is not indexed, so
  it does no harm there. [codegraph.md](codegraph.md) covers how it is set up here and everywhere
  else, and how to roll it back.

The file may list others, such as `rider` and `webstorm`, the JetBrains IDEs' own MCP servers over
`http` on the loopback address. The image build checks only the four required servers, so adding
another server does not break it (#1850).

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

One further check is deliberately non-fatal: the entrypoint compares the SHA recorded in
`/workspace/rules/.env` with the SHA published at `https://pre-commit.markridgwell.com/sha.txt`.
Either side may be an abbreviated SHA, so only the common prefix (at least 7 characters) is
compared. A mismatch prints a single warning naming both SHAs and saying the rules checkout is
stale, then startup continues: the installed hooks still run at their installed version, and a
slightly stale lint set is far cheaper than every agent run failing whenever the published SHA
moves ahead of the host-side rules sync. To clear the warning, update the host's rules checkout.
The check is skipped silently when the `.env` file or its `SHA=` line is absent, `curl` is
unavailable, the remote is unreachable, or the remote returns something that is not a hex SHA.

Secret-bearing files in the repository checkout are masked before the container starts. For
every untracked or ignored regular file under the repository whose name matches a pattern in
`claude-hooks/secret-files` (`.env`, `.env.*`, `*.env`, `.database`), the launcher adds a
read-only bind mount of `/dev/null` over its path inside the container, so the agent sees an
empty file in its place, and prints a warning listing the files it masked. The `.git`
directory is skipped and symlinks are not followed. A matching file that git tracks is not
masked: its content is already in the repository and its history, and masking it would make
git inside the container fail every commit (`cannot hash`). The tracked set is read once with
`git ls-files -z`, and one line lists the tracked matches left unmasked. If `git ls-files`
fails, every match is masked, tracked or not. `.env.example`, the conventional committed
template, is never masked and the hook always allows it, wherever it is and whether or not it
is tracked; every other `.env.*` name (such as `.env.local`) is still masked and blocked. Inside the container, the
`block-secret-file-reads` hook is a second layer: it denies any `Bash`, `Read`, `Edit`, `Write`
or `NotebookEdit` call that names a file matching the same patterns, including through a glob
or a symlink. A tool inside the container that needs one of these files therefore sees it as
empty.

Just before it starts `claude`, the entrypoint builds the CodeGraph index that the managed
`codegraph` MCP server reads, but only when there is none. When `.codegraph/codegraph.db` is
missing or empty it runs `codegraph init --yes` in the repository checkout with stdin closed, which
creates `.codegraph/` and builds the full index. Otherwise it leaves the index alone and runs no
`codegraph` command: `.codegraph/` is the item's own host directory, which persists between that
item's containers (see [The CodeGraph index](#the-codegraph-index)), and the MCP server catches
the existing index up with changes since the item's last session when Claude connects, before it
answers the first query. Its watcher then keeps the index current while the session runs. This
step is non-fatal: if `codegraph init` fails, the entrypoint prints a warning and still starts
`claude`, because a missing index only makes code lookups slower. The build is also time-limited,
because it runs inside the session's `AGENT_TIMEOUT_MINUTES` and a hung build would otherwise end
the session as an agent timeout: after `CODEGRAPH_INIT_TIMEOUT_SECS` (default 900, set in
`lib/globals`, which clamps a value above half of the session's limit to half of it, so the build
and the 10-second kill grace below always end well inside that limit, and passed in
by `oneshot`) the entrypoint stops it, killing it 10 seconds later
if it ignores the stop (exit 137, reported as killed rather than timed out, because the kernel
OOM killer's SIGKILL gives the same status), prints a warning and starts
`claude` without an index. After any failed, timed-out or killed `init` the entrypoint deletes
everything inside `.codegraph/` (never the directory itself, which is a mountpoint), because the
directory persists and `init` treats a half-built database that already has its schema as
initialized; the next session then runs `init` again from empty. It is skipped when the
checkout has no `.git` directory, in pre-check mode (below), and when the checkout tracks any
file under `.codegraph/` (see [The CodeGraph index](#the-codegraph-index)). Running it before `claude` keeps
indexing from competing with the agent's own builds and tests for the container's memory.
`codegraph init` writes `.codegraph/.gitignore`, which ignores everything else in that directory.
That file is itself left untracked, and the image sets no global git excludes file to hide it.
So before indexing, the entrypoint adds `.codegraph/` to the checkout's `.git/info/exclude`
(`exclude_codegraph_from_git`), which keeps a `git add -A` from committing it in a repository
whose `.gitignore` does not yet ignore `.codegraph/` (see
[codegraph.md](codegraph.md#every-repository)). It runs in pre-check mode too, appends the line
only when it is missing, creates `.git/info/` when needed and never touches the tracked
`.gitignore`. If the write fails it only warns, because the repository's own `.gitignore` may
already ignore `.codegraph/`. It adds no entry when the checkout tracks any file under
`.codegraph/`, because the entry would hide new files there from `git`.
Because the mount sits over the checkout, `git` inside the container sees those files exactly as
it would in a plain directory.

Only once every one of these passes does the entrypoint exec `claude` itself, handing it the
prompt built by `oneshot` (see [oneshot.md](oneshot.md) and
[workflow-board.md](workflow-board.md) for what that prompt actually contains).

The one exception is the pre-check (#1785): when `oneshot` starts the image with
`ORCHESTRATOR_PRECHECK=1`, the entrypoint runs the same checks, prints
`orchestrator-precheck: running pre-commit-check`, and execs `pre-commit-check` in the repo
checkout instead of `claude`. No model runs. `oneshot` uses it before a session to check a PR's
head (or `main`'s tip for an issue session) and puts the result in the agent's prompt; see
`run_precommit_precheck` in [development/lib.md](development/lib.md).

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
```

Every launch has a work item: `invoke_claude` refuses to start a container without both an item
type and an item id, before it creates any temporary file or Podman secret. The directories are
created mode `0700`: transcripts contain verbatim command text and output, and nothing redacts
them.

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
(`lib/podman`), through `prune_idle_item_dirs`, the logic it shares with the
[CodeGraph index](#the-codegraph-index) purge. It does not depend on an item closing: a merged
PR and the Issue it closes drop out of the priorities feed, so `oneshot` almost never sees an
item closed.

- An item's whole transcript directory is deleted once no file in it has been modified for
  14 days (`TRANSCRIPT_ITEM_RETENTION_DAYS` in `lib/globals`, which also sets the CodeGraph
  index retention). Its age is the newest file modification time under it, found without
  following links; the directory's own modification time is not used, because appending to a
  transcript does not change it. A directory that contains no files is aged by its own
  modification time.
- A pivoted PR's link is never followed and is never deleted while its target exists. The PR's
  sessions write into the Issue's directory through it, so that directory stays fresh while the
  PR is being worked, and both go together once it has been idle for 14 days. A link whose
  target no longer exists is deleted (the link only, never anything through it), including one
  left dangling by the same pass.

The purge never queries GitHub and never fails the run: a directory it cannot read or delete is
kept, with a warning, until the next launch. As a result, an item that is still open but has had
no session for 14 days loses its transcripts; that is acceptable because `oneshot` never resumes
a session, and the next session starts a fresh directory. The purge also only covers the
repository being launched for, so idle transcripts in a repository with no further launches wait
until that repository's next one.

`oneshot` never resumes a session: every phase starts a fresh one, and the transcripts
exist so a human can read afterwards what an agent did and why.

## The CodeGraph index

The index the entrypoint builds lives outside the repository checkout, in a host directory per
work item, bind-mounted at `/workspace/repo/.codegraph`:

```text
${XDG_STATE_HOME:-~/.local/state}/orchestrator/<owner>/<repo>/codegraph/Issue_<n>/
${XDG_STATE_HOME:-~/.local/state}/orchestrator/<owner>/<repo>/codegraph/PullRequest_<n>/
```

`oneshot` runs `git clean -fdX` in the checkout after every session and after every pre-check,
which deletes every ignored file. An index kept in the checkout would be deleted with them, so
every session would start with a full `codegraph init`. Kept in the item's own directory, it
follows the same lifecycle as the [session transcripts](#session-transcripts):

- Every session for the same item mounts the same directory, so the entrypoint runs nothing and
  the MCP server catches the existing index up when Claude connects.
- A session for a different item mounts that item's directory, which starts empty, so the
  entrypoint runs a fresh `codegraph init`. The other item's index is not touched.
- On the Issue-to-PR pivot, `codegraph/PullRequest_<m>` becomes a link to `Issue_<n>`, by the
  same rules as the transcript link (`link_pivot_pr_codegraph_index` in `lib/state`), so the PR's
  sessions reuse the index the Issue's sessions built, which the MCP server catches up on connect.
  The pivot counts as activity here too, but it touches `Issue_<n>/` itself rather than writing
  `.orchestrator-last-pivot` into it, because the directory is CodeGraph's own `.codegraph` in
  the container and the purge below counts its modification time as use.
- Before every launch, `prune_codegraph_indexes` (`lib/podman`) applies the transcript purge
  (`prune_idle_item_dirs`, with the same `TRANSCRIPT_ITEM_RETENTION_DAYS`) to this tree, with
  one difference: the directory's own modification time also counts as use. A session that
  only queries the index writes no file in it, so `add_codegraph_index_podman_args` touches
  the directory each time it is mounted (through a pivoted PR's link, the Issue's directory).
  An item's directory is therefore deleted once no session has mounted it and no file in it has
  been modified for 14 days, and a link whose target is gone is deleted. The purge runs before
  the mount, so an index last used more than 14 days ago is still deleted and the session
  starts a fresh `init`.

The directory is created mode `0700` before the mount, because the index holds the repository's
code. If it cannot be created, `oneshot` warns and starts the session without the mount; the
entrypoint then builds an index in the checkout, which the `git clean` afterwards deletes. The
host skips the mount, with a warning, when the checkout tracks any file under `.codegraph/`:
the mount would hide those files, `git` in the container would see them as deleted, and the
agent's `git add -A` could commit the deletion. The index directory is then neither created nor
touched. The entrypoint makes the same `git ls-files -- .codegraph` check itself
(`checkout_tracks_codegraph`), so it cannot disagree with the checkout the container sees, and
then skips CodeGraph: it runs no `init`, so it neither rewrites the tracked files nor deletes
them in the clean-up after a failed `init`, and adds no `.git/info/exclude` entry. It prints one
warning naming the reason, and the session runs without an index. The managed MCP server still
starts; with no index it only answers that the project is not indexed, but if the repository
commits a non-empty `.codegraph/codegraph.db` its catch-up and watcher can still update that
file. Only
the agent's own container gets the mount. The pre-check container does not, because the
entrypoint never builds or reads the index in pre-check mode. Podman creates the empty
`.codegraph` mountpoint in the checkout, and the `git clean` after the session removes it. That
works in every repository, because `git clean -X` removes only ignored files and the
entrypoint's `.git/info/exclude` entry makes `.codegraph/` ignored even where `.gitignore` does
not list it.
CodeGraph's SQLite database and its lock files sit on a plain bind mount of a local directory,
owned by the user the container's `developer` maps to, so they behave as they would in the
checkout.

### Security note: the index is writable

The index is mounted read-write (`:rw` in `add_codegraph_index_podman_args`), because the
entrypoint's `init` and the MCP server's catch-up both write to it. So a prompt-injected
session could alter `codegraph.db` (the image includes `sqlite3`), and later sessions on the
same item would then get planted source from `codegraph_explore`. This is an accepted risk,
not an oversight: the index is built from the same checkout, which the agent can already write
to, and agents read the files directly anyway, so a poisoned index crosses no trust boundary
that a poisoned checkout does not. Two things limit it:

- The index is per item. It is never shared with another item or repository; the only sharing
  is between an Issue and the PR it pivots to, through the link described above.
- An index nothing has used for 14 days is purged, as described above.

To discard an index you no longer trust, delete the item's directory (and, for an Issue that
has pivoted, the PR's link to it, or the purge removes the dangling link later). The next
session for that item starts with an empty directory, so the entrypoint runs a fresh
`codegraph init`.

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
