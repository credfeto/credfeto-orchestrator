# How CodeGraph is set up and rolled out

## The simplest possible explanation

[CodeGraph](https://github.com/colbymchenry/codegraph) reads a repository with tree-sitter and
builds a local graph of its symbols and the calls between them, stored in `.codegraph/` at the
repository root. `codegraph serve --mcp` hands that graph to Claude Code as MCP tools, such as
`codegraph_explore`. One `codegraph_explore` call returns the relevant symbols' source together
with the call paths between them, including dynamic-dispatch hops that grep cannot follow. With
grep and file reads, the same answer takes several calls. Agents use only the MCP tools: they
have no shell access to the `codegraph` CLI, which the entrypoint uses to build the index before
Claude starts, and which a person can run in their own terminal.

The aim is fewer tool calls and tokens when agents explore code. That gain has not been measured
here, so the rollout is built to be undone in one go (see [Rollback checklist](#rollback-checklist)).

Upstream's README lists full support for the languages the agents work in here: C#, Python, and
TypeScript/JavaScript.

"Everywhere" means five places, each set up separately:

| Place | What it needs | Status |
| --- | --- | --- |
| [Agent container](#agent-container) | Pinned CLI, managed MCP server, MCP permission, index at start | Done in this repository |
| [Developer workstations](#developer-workstations) | Pinned CLI, Claude Code wiring, `install-claude-hooks` re-run, per-repository index | Manual, per workstation |
| [Every repository](#every-repository) | `.codegraph/` in `.gitignore` | Templates done; reaches each repository through the `.gitignore` sync. The agent container also excludes it in every checkout it works on |
| [Agent definitions](#agent-definitions) | `mcp__codegraph__*` in the agents' tool lists, plus a usage note | [credfeto/credfeto-ai-skills#60](https://github.com/credfeto/credfeto-ai-skills/issues/60) |
| [Shared instructions](#shared-instructions) | The CodeGraph section in cs-template's global instructions | Not started |

## Agent container

This repository's `development-full` image, and the agent image built on it, has everything
CodeGraph needs. Nothing has to be done by hand.

- **The CLI.** `containers/base/development-tools/Dockerfile` downloads the standalone Linux release
  archive (`codegraph-linux-x64.tar.gz` or `codegraph-linux-arm64.tar.gz`) and checks it with
  `sha256sum -c` before unpacking it. The archive is a directory holding a launcher, a bundled Node
  runtime and the app, so no system Node.js is needed. It is unpacked into `/opt/codegraph`, owned
  by root, and `/usr/local/bin/codegraph` links to the launcher. `development-full` inherits it
  through its base image chain. The sanity stages of both images check that `codegraph` is on
  `PATH` and that `codegraph --version` runs.
- **The pin.** The version is pinned by `ARG CODEGRAPH_VERSION`, with one checksum per
  architecture in `CODEGRAPH_SHA256_AMD64` and `CODEGRAPH_SHA256_ARM64`. The Dockerfile is the only
  place these values are kept; this guide does not copy them.
  `.github/workflows/bump-pinned-tool-versions.yml` runs daily at 02:00 UTC, and can be started by
  hand. `codegraph` is one of its matrix tools, alongside the other pinned tools in the
  `development-tools` Dockerfile. When a newer release exists, the action rewrites all three ARGs,
  using checksums computed from the new release's own assets, and opens a PR. The image build CI
  check then validates the new pin before it is merged.
- **Telemetry.** Upstream telemetry is on by default. `development-tools` sets
  `CODEGRAPH_TELEMETRY=0`, which the images built on it inherit.
- **The MCP server.** `containers/base/development-full/claude-managed-mcp.json` registers
  `codegraph`. The entry is exactly what `codegraph install` writes for Claude Code, and the image
  build fails if it differs:

  ```json
  "codegraph": {
    "type": "stdio",
    "command": "codegraph",
    "args": ["serve", "--mcp"],
    "alwaysLoad": true
  }
  ```

- **Permissions.** `claude-managed-settings.json` allows `mcp__codegraph__*` and no
  `Bash(codegraph ...)` entry, and the hook allowlist, `claude-hooks/command-allowlist`, does not
  list `codegraph`, so `reject-obfuscated-commands` rejects every `codegraph` shell command an
  agent runs. Agents explore code only through the `codegraph_explore` MCP tool. They need no
  `sync` either: the MCP server catches an existing index up when Claude connects, and its
  watcher updates the index as files change. The entrypoint's own `codegraph init` runs before
  Claude, outside the hooks and permissions, so it is unaffected.
- **The index.** The entrypoint builds the index just before it starts `claude`, only when it is
  missing: with no `.codegraph/codegraph.db` it runs `codegraph init --yes -v`; otherwise it runs
  no `codegraph` command, and the MCP server catches the existing index up with the working tree
  when Claude connects, before it answers the first query. The index does not live in the host's checkout, where the `git clean -fdX`
  after every session would delete it. `oneshot` mounts a host directory per work item at
  `.codegraph`, so the index persists between that item's containers, an Issue and the PR it
  pivots to share one, a different item starts with a fresh `init`, and a directory idle for
  14 days is purged, the same lifecycle as the session transcripts. See
  [agent-container.md](agent-container.md#the-codegraph-index) for the details. While the
  session runs, the MCP server watches the checkout and updates the index as files change.
- **Time and memory.** The first `init` for a work item builds the whole index. On a large
  repository that can take minutes, which delays the start of that one session. Later sessions
  for the same item run no indexing step at start: the MCP server's catch-up on connect only reads
  what changed. The full `init` runs before `claude` starts, so it never competes with the
  agent's own builds and tests for the container's memory limit (`--memory=12g` in
  `lib/podman`). CodeGraph sizes its workers and memory from the container's cgroup limits
  itself, so no tuning is set.
- **Without an index.** If `init` fails, the entrypoint prints a warning and starts `claude`
  anyway, because a missing index only makes code lookups slower. In a repository with no index,
  the MCP tools answer that the project is not indexed, and agents fall back to grep and file
  reads.

To undo this part, revert the PR that added it (see [Rollback checklist](#rollback-checklist)).

## Developer workstations

Each workstation is set up by hand. The steps below assume Linux on x64 or arm64 with glibc,
the only platforms the pinned archives cover. Other platforms are listed on the
[releases page](https://github.com/colbymchenry/codegraph/releases).

1. **Install the pinned CLI.** The script reads the version and checksum from the `CODEGRAPH_*`
   ARGs in `containers/base/development-tools/Dockerfile`, so the workstation runs the same version
   as the agents. Run it from the root of an up-to-date checkout of this repository. This uses the
   same layout as upstream's installer, without its install script, which verifies nothing:

   ```bash
   dockerfile=containers/base/development-tools/Dockerfile
   arch=x64      # or arm64
   case "${arch}" in
       x64) sha256_arg=CODEGRAPH_SHA256_AMD64 ;;
       arm64) sha256_arg=CODEGRAPH_SHA256_ARM64 ;;
   esac
   version=$(grep '^ARG CODEGRAPH_VERSION=' "${dockerfile}" | cut -d= -f2)
   sha256=$(grep "^ARG ${sha256_arg}=" "${dockerfile}" | cut -d= -f2)
   tmp=$(mktemp -d)
   curl -fsSL "https://github.com/colbymchenry/codegraph/releases/download/v${version}/codegraph-linux-${arch}.tar.gz" \
       -o "${tmp}/codegraph.tar.gz"
   echo "${sha256}  ${tmp}/codegraph.tar.gz" | sha256sum -c -
   mkdir -p "${HOME}/.codegraph/versions/v${version}" "${HOME}/.local/bin"
   tar -xzf "${tmp}/codegraph.tar.gz" -C "${HOME}/.codegraph/versions/v${version}" --strip-components=1
   ln -sfn "${HOME}/.codegraph/versions/v${version}/bin/codegraph" "${HOME}/.local/bin/codegraph"
   rm -rf "${tmp}"
   codegraph --version
   ```

   `~/.local/bin` must be on `PATH`, because the MCP entry runs a bare `codegraph`. To move to a
   new pin, pull the checkout and repeat this step. Do not run `codegraph upgrade`
   with no version, because it moves to upstream's latest release rather than the pin.

1. **Turn telemetry off.** Run `codegraph telemetry off`, or set `CODEGRAPH_TELEMETRY=0` in the
   shell profile.

1. **Wire it into Claude Code.** Run:

   ```bash
   codegraph install --target claude --location global --no-permissions
   ```

   It asks whether to add a "front-load" prompt hook (answer no). It only asks about sharing usage
   statistics if no telemetry choice has been stored yet; after the previous step it has, but if it
   does ask, answer no. Do not use `--yes`: it turns the prompt hook on and leaves telemetry at its
   default. The command writes two things that matter here:
   - The `codegraph` entry in the top-level `mcpServers` of `~/.claude.json`, identical to the
     managed entry shown under [Agent container](#agent-container).
   - A `## CodeGraph` section in `~/.claude/CLAUDE.md`, between `<!-- CODEGRAPH_START -->` and
     `<!-- CODEGRAPH_END -->`. It tells agents to use CodeGraph in repositories that have a
     `.codegraph/` directory.

   The permissions and prompt hook it can also write go into `~/.claude/settings.json`, and are
   ignored on a host set up with `install-claude-hooks`. The managed settings set
   `allowManagedPermissionRulesOnly`, `allowManagedHooksOnly` and `allowManagedMcpServersOnly`, and
   each run of `install-claude-hooks` replaces `~/.claude/settings.json`, keeping the old file as
   `settings.json.bak`. That is why the command uses `--no-permissions`.

   Instead of `codegraph install`, the `~/.claude.json` entry can be added by hand. If it is, it
   must be identical to the managed entry. `install-claude-hooks` merges an identical entry
   silently as the same server, but stops on any difference under the same name:

   ```text
   MCP server name(s) used for two different servers in <home>/.claude.json or by the shipped managed-mcp.json: codegraph. Rename one of each pair and re-run.
   ```

   Once the managed file ships `codegraph`, the `~/.claude.json` entry is optional, so the fix is
   to make it identical or remove it.

1. **Re-run `install-claude-hooks` after the container change is merged.** Pull this repository's
   checkout first. The re-run installs the managed files that now include CodeGraph:
   `mcp__codegraph__*` in the managed permissions and the `codegraph` server in
   `/etc/claude-code/managed-mcp.json`. Claude Code sessions reach CodeGraph only through the MCP
   tools; the host's hooks still refuse every `codegraph` shell command a session runs, because
   `codegraph` is not on the hook allowlist. Start a new Claude Code session to pick up the change.

1. **Index the repositories you want.** On a workstation, indexing is the user's decision. First
   check that the repository ignores `.codegraph/` (see [Every repository](#every-repository)):

   ```bash
   git check-ignore -q .codegraph/ && echo ignored
   ```

   Then run `codegraph init --yes` at the repository root, in your own terminal rather than
   through Claude Code, whose hooks refuse `codegraph`. The MCP server's watcher keeps the index
   current while a session runs; `codegraph sync`, run the same way, catches up by hand.
   `codegraph uninit --force` deletes the index.

To undo a workstation, see [Rollback checklist](#rollback-checklist).

## Every repository

Every repository has to ignore `.codegraph/`, because the index is local and must never be
committed. The ignore comes from the templates:

- `funfair-tech/funfair-server-template`: done (commit 02a8a0fa).
- `credfeto/cs-template`: done, under a `# Codegraph` heading.

Existing repositories get the lines through the `.gitignore` sync from the templates, as commits
titled `[Gitignore config] Updated .gitignore`. This repository got it that way. If the sync does
not cover a repository, add the two lines by hand:

```gitignore
# Codegraph
.codegraph/
```

`git check-ignore -q .codegraph/` confirms the result.

**The container closes the gap.** `codegraph init` writes `.codegraph/.gitignore` (`*` and
`!.gitignore`). That keeps the index itself out of git, but leaves that one file visible. In a
repository that does not yet ignore `.codegraph/`, a `git add -A` would commit
`.codegraph/.gitignore`. So before it indexes, and in pre-check mode too, the agent container's
entrypoint adds `.codegraph/` to the checkout's `.git/info/exclude` (`exclude_codegraph_from_git`
in `containers/agent/entrypoint.sh`). It appends the line only when it is missing, creates
`.git/info/` when needed, and never touches the repository's tracked `.gitignore`. If the write
fails it only warns (see
[agent-container.md](agent-container.md#what-the-entrypoint-checks-before-the-agent-ever-starts)).
The exclude is local to that checkout and is never pushed, so the `.gitignore` lines above are
still wanted. On a workstation nothing writes the exclude, so check that a repository ignores
`.codegraph/` before indexing it there.

To undo this part, leave the ignore line in place. It does nothing when no index exists.

## Agent definitions

The agent definitions come from `credfeto/credfeto-ai-skills` and are linked into the image at
build time. Agents whose definitions have an explicit `tools:` list cannot call MCP tools that the
list does not name. The six code-review lenses only have `Read`, `Grep`, `Glob` and `Skill`, and
no agent has a `codegraph` shell fallback, so they cannot use CodeGraph at all.
[credfeto/credfeto-ai-skills#60](https://github.com/credfeto/credfeto-ai-skills/issues/60) adds
`mcp__codegraph__*` to those tool lists, including the six lenses, and adds a shared
`credfeto-codegraph` skill with the usage note. Until it lands, only the main session and agents
without an explicit tool list can use CodeGraph.

Once it merges, the next image build picks it up. Workstations pick it up when their agents are
next installed from `credfeto/credfeto-ai-skills`.

To undo this part, revert that change in `credfeto/credfeto-ai-skills` and rebuild the image.

## Shared instructions

This is described here only; none of it has been done.

The CodeGraph section is in each user's own `~/.claude/CLAUDE.md`, written by `codegraph install`,
so agents in the container never see it. It should move into cs-template's global instructions
(a file under `ai/global`, listed in `ai/global/index.md`). Its last line also has to change,
because the container now indexes automatically, and its shell bullet is dropped, because agents
have no shell access to `codegraph`. Suggested text:

```markdown
## CodeGraph

In a repository indexed by CodeGraph (a `.codegraph/` directory exists at the repository root), use it before grep, find or reading files to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call, returning the relevant symbols' source and the call paths between them. Name a file or symbol in the query to read its current line-numbered source. If it is listed but deferred, load it by name through tool search.

The agent container indexes every repository automatically before the session starts. On a workstation, indexing is the user's decision: if there is no `.codegraph/` directory, skip CodeGraph.
```

Once it is in cs-template, delete the block between `<!-- CODEGRAPH_START -->` and
`<!-- CODEGRAPH_END -->` from `~/.claude/CLAUDE.md`. `codegraph install` writes the block again,
and so does `codegraph upgrade`, which re-runs the install for agents that are already set up. After
either, remove the block again, or accept the duplicate.

To undo this part, revert the cs-template change.

## Rollout order

1. Confirm that the repositories the agents work on ignore `.codegraph/` (templates done; check
   that the sync has reached them). The container's `.git/info/exclude` entry covers a repository
   the sync has not reached yet.
1. Merge this repository's container change. The image rebuilds, and the next agent sessions
   index their repository at start.
1. Merge [credfeto/credfeto-ai-skills#60](https://github.com/credfeto/credfeto-ai-skills/issues/60)
   and rebuild the image, so sub-agents and review lenses can call the tools.
1. On each workstation: install the pinned CLI, turn telemetry off, run `codegraph install`, re-run
   `install-claude-hooks`, and index the repositories wanted.
1. Move the CodeGraph section into cs-template's global instructions and remove the per-user
   block.

## Judging whether it is worth it

No numbers were measured before rollout. Judge it from real use over a few weeks by comparing
similar tasks before and after:

- Whether agents call it at all: search the session transcripts (see
  [agent-container.md](agent-container.md#session-transcripts)) for `mcp__codegraph__` tool calls.
- Tool calls per session, especially `Grep`, `Glob` and `Read`, for comparable issues.
- Tokens per session, and wall-clock time.
- The delay indexing adds to session start: the entrypoint logs `Running codegraph init` when it
  builds a missing index, `CodeGraph index already exists` when it skips an existing one, and a
  warning containing `failed in` when `init` fails.

If agents rarely call it, or the counts do not drop, roll it back.

## Rollback checklist

1. **Container.** Revert this repository's PR (#1885) as one revert. That removes the CLI, the
   managed MCP entry, the MCP permission, the indexing at start, the per-item
   index mount and its 14-day purge, the entrypoint's `.git/info/exclude` entry, the bump
   workflow entry, this guide and the CodeGraph notes in the other docs. The image rebuilds
   without CodeGraph. Two things stay, both harmless: the `.codegraph/` lines already written to
   checkouts' `.git/info/exclude` (see **Repositories** below), and the indexes already built on
   each host that runs `oneshot`, under
   `${XDG_STATE_HOME:-~/.local/state}/orchestrator/<owner>/<repo>/codegraph/`. With the purge
   gone, the indexes stay until deleted by hand. To reclaim the space, delete the `codegraph/`
   directory under each repository's state directory, for example
   `rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}"/orchestrator/*/*/codegraph`.
1. **Agent definitions.** Revert the change from
   [credfeto/credfeto-ai-skills#60](https://github.com/credfeto/credfeto-ai-skills/issues/60) and
   rebuild the image.
1. **Shared instructions.** Revert the cs-template change, if it was made.
1. **Each workstation**, in this order, because the CLI is needed for the first two steps:
   1. In each indexed repository, run `codegraph uninit --force`, which deletes `.codegraph/`.
   1. Run `codegraph uninstall --target claude --location global`. It removes the `~/.claude.json`
      entry, the `~/.claude/CLAUDE.md` block and any permissions it wrote, and also the CLI unless
      `--keep-cli` is given. If `command -v codegraph` still finds it, delete
      `~/.local/bin/codegraph` and `~/.codegraph/`.
   1. Pull the reverted checkout of this repository and re-run `install-claude-hooks`, so the
      managed files no longer list `codegraph`. The order matters: a `codegraph` entry still in
      `~/.claude.json` would be copied back into `/etc/claude-code/managed-mcp.json`.
1. **Repositories.** Leave `.codegraph/` in `.gitignore`. The `.codegraph/` line the container
   added to each checkout's `.git/info/exclude` is local, never pushed and harmless; it can be
   left or deleted by hand.
