# credfeto-orchestrator

Orchestrator tooling for driving Claude Code agents to work on GitHub issues and pull requests.

## oneshot

The `oneshot` script fetches the top-priority open work item for `credfeto/credfeto-orchestrator`
from the [priorities API](https://git-workflow.markridgwell.com/priorities) and invokes a
Claude Code session to work on it.  When the GitHub login `gh` is authenticated as can be
resolved, it is sent URL-encoded as the optional `user` query parameter
(`/priorities?user=<login>`) so the feed can leave out items assigned to other users; otherwise
the feed is fetched without it.  Every run starts a fresh session and never resumes an
earlier one; the state that carries between runs lives in GitHub.  Under
`${XDG_STATE_HOME:-$HOME/.local/state}/orchestrator/<owner>/<repo>` the script keeps per-item
bookkeeping files named `<ItemType>_<id>.<suffix>` (change-detection fingerprints, invocation
counters and block markers) and each item's session transcripts in
`transcripts/<ItemType>_<id>/`, kept so a human can read what the agent did.  When an issue
pivots to its PR, the PR's transcript directory is linked to the issue's, so both share one
history.  An item's transcripts are deleted once none of them has been modified for 14 days,
whether the item is open or closed.  An issue that pivots to its PR keeps its transcripts for as
long as it keeps pivoting, because each pivot counts as activity; see
[docs/agent-container.md](docs/agent-container.md#session-transcripts).

### Usage

```sh
./oneshot
```

### Requirements

- `curl`
- `jq`
- `claude` (Claude Code CLI)
- `gh` (GitHub CLI, authenticated)

### Per-owner OAuth token

By default, the script uses whatever `CLAUDE_CODE_OAUTH_TOKEN` is already set in the environment.
To charge Claude usage to a specific owner's Anthropic account, create a token file for that owner.

**Preferred location (XDG):**

```text
$XDG_CONFIG_HOME/orchestrator/tokens/<owner>
```

(defaults to `~/.config/orchestrator/tokens/<owner>` when `$XDG_CONFIG_HOME` is not set)

The file should contain the raw OAuth token; any surrounding whitespace is stripped automatically.
The token is scoped to the `claude` invocation via `env CLAUDE_CODE_OAUTH_TOKEN=...` and is never written to log output.

**File permissions — set `600` to prevent other users from reading the token:**

```sh
chmod 600 "${XDG_CONFIG_HOME:-${HOME}/.config}/orchestrator/tokens/<owner>"
```

Example — storing a token for the `credfeto` owner:

```sh
mkdir -p "${XDG_CONFIG_HOME:-${HOME}/.config}/orchestrator/tokens"
printf '%s' '<oauth-token>' > "${XDG_CONFIG_HOME:-${HOME}/.config}/orchestrator/tokens/credfeto"
chmod 600 "${XDG_CONFIG_HOME:-${HOME}/.config}/orchestrator/tokens/credfeto"
```

If no token file exists, the script falls back to `CLAUDE_CODE_OAUTH_TOKEN` from the environment,
preserving the existing behaviour for installations that do not require per-owner billing.

> **Note:** The current script is configured for the `credfeto` owner. As the orchestrator is
> extended to cover additional repos, set `OWNER` accordingly and create a token file for each owner.

### Discord webhook notifications (optional)

The script can post notifications to a Discord channel via a webhook whenever:

- An issue or PR is **picked up** (a fresh session is about to start on it), with a link to the item.
- An issue or PR is found to be **blocked** (has the `Blocked` label), with a link to the item.
- **No actionable work items** are found after scanning all priorities.
- A session **stalled**: it stopped because it believed a tool was denied, or hit permission denials and its PR made no progress.
- A new day starts: a **daily session digest** of the previous day's sessions, denials and stalled sessions per repository (one per missed day when the host was down across midnight).

See [How Discord notifications work][discord-notifications] for the full list.

**Config file location:**

```text
$XDG_CONFIG_HOME/orchestrator/.env
```

(defaults to `~/.config/orchestrator/.env` when `$XDG_CONFIG_HOME` is not set)

**File permissions — set `600` to prevent credentials being read by other users:**

```sh
chmod 600 "${XDG_CONFIG_HOME:-${HOME}/.config}/orchestrator/.env"
```

### GitHub CLI proxy (`GH_HOST` + `GH_TOKEN`)

When `GH_HOST` and `GH_TOKEN` are both set, `oneshot` exports them as `GH_HOST` and
`GH_ENTERPRISE_TOKEN` so that all `gh` CLI calls — both on the host and inside the agent
container — route through the same GitHub API proxy:

```dotenv
GH_HOST=github-api.example.com
GH_TOKEN=ghp_<your-proxy-token>
```

If either key is absent, `gh` on the host falls back to its own `~/.config/gh/hosts.yml`.
Inside the agent container there is no `hosts.yml`: the image bakes the proxy `GH_HOST` with a
placeholder token, so without both keys `gh` in the container is unauthenticated. For direct,
unproxied access set `GH_HOST=github.com` with a real token; the container's `gh` then gets it as
`GH_TOKEN` rather than `GH_ENTERPRISE_TOKEN`, which `gh` ignores for github.com.

Inside the agent container the token is never in the agent's environment: it is mounted as a
root-only file that only a root-owned token broker reads, and `gh` there is a wrapper that asks the
broker to run the real `gh` with it (see
[docs/development/claude-hooks.md](docs/development/claude-hooks.md#the-token-broker)).

### Knowledge-base MCP token (`KB_MCP_TOKEN`, optional)

The agent container's `kb` MCP server (`https://memory.markridgwell.com/dev/mcp`) needs a bearer
token. Set it in `.env`:

```dotenv
KB_MCP_TOKEN=<your-kb-token>
```

`oneshot` passes it to each container as a per-container Podman secret, mounted as a root-only
file that the token broker reads to answer the server's root-owned `headersHelper`, and removes
the secret when the container exits. It is never written to the image or to `managed-mcp.json`.
Without it, sessions still start, and `kb` shows as failed to connect. A value holding a character
a bearer token cannot contain (a space, a trailing `# comment`, a stray quote) is ignored with a
one-line warning that names the key but never prints the value, as if it were unset.

On a developer machine set up with `install-claude-hooks`, export `KB_MCP_TOKEN` where `claude`
runs, or write the token to `${XDG_CONFIG_HOME:-$HOME/.config}/kb-mcp/token` with mode `600`; the
helper refuses that file if it is not a regular file you own with exactly that mode.

### Discord notifications (`DISCORD_WEBHOOK`)

To enable, add a `DISCORD_WEBHOOK` entry:

```dotenv
DISCORD_WEBHOOK=https://discord.com/api/webhooks/<id>/<token>
```

If `DISCORD_WEBHOOK` is absent or the file does not exist, Discord notifications are silently skipped.

### GitHub health gate

At the start of every tick, after taking the lock and before fetching priorities, `oneshot`
reads GitHub's unresolved incidents from
[githubstatus.com](https://www.githubstatus.com/api/v2/incidents/unresolved.json) (a single
`curl` with a 5 second connect timeout and a 10 second total timeout). If an incident is open on
any of the components the agent's sessions depend on (**Git Operations**, **Pull Requests**,
**Issues**, **API Requests** or **Webhooks**), the tick does no work at all. It logs one line:

```text
GitHub incident open (<incident name>, since <start time>) — skipping work this tick
```

and exits 0, as the low-disk-space skip does, so the systemd unit does not record a failure.

Without the gate, every session in an outage fails its pre-flight or is charged against its
item's idle budget for "making no progress", because it cannot push, comment or move a board
card, and a healthy PR can be marked `Blocked` as idle-exhausted within minutes. No session runs
in a tick the gate stops, so no idle budget is charged and no PR is parked.

- Incidents only on other components (for example Codespaces, Copilot or Actions) do not stop
  the tick.
- The gate fails open: if githubstatus.com cannot be reached, times out or returns something that
  is not the expected JSON, `oneshot` logs a warning and carries on as before, so a problem with
  the status page never stops the fleet on its own.
- `GITHUB_STATUS_URL` overrides the status URL (the tests point it at a local `file://` fixture).

The agent container's pre-flight SSH check can still fail during an outage that githubstatus.com
has not reported yet. Its "SSH key is not authorized to access GitHub" message therefore says
that this can also be a GitHub Git Operations outage, and to check githubstatus.com before
re-registering the key.

That failure is also the gate's second guard. When a session's container fails pre-flight with
that message, `oneshot` treats it as a likely GitHub outage, because every further item in the
tick would fail the same check. It logs:

```text
pre-flight git SSH auth failed — treating as a likely GitHub outage, skipping the rest of this tick
```

picks no further items and exits 0, so the unit does not record a failure.

- As with any pre-flight failure, the attempt is not counted against the item's invocation
  budget, and the item's consecutive pre-flight failure counter still advances. A key that GitHub
  really does refuse is therefore still marked `Blocked` after `MAX_CONSECUTIVE_INFRA_FAILURES`
  ticks in a row.
- Other pre-flight failures behave as before: `oneshot` moves on to the next item and, if no
  session runs, exits 1 so the unit's failure alert fires. If an earlier item in the same tick
  failed pre-flight for another reason, the tick still exits 1.

### Unit-failure alerts (`notify-unit-failure`)

`setup-owner` also installs a `<service>-failure.service` unit, wired to the main service's
`OnFailure=`, which runs the `notify-unit-failure` script and posts to the same
`DISCORD_WEBHOOK`.

It exists because every alert `oneshot` sends is one `oneshot` was healthy enough to send: a
failure that stops it before it reaches its own notification code is invisible. Running the
alert from a *separate* unit is what makes that class of failure audible — a stale podman
container name once made every invocation fail for 19.5 hours with no alert at all
(credfeto-orchestrator#1361).

It reuses the same config key as above, deliberately shares no code with `lib/` (everything
there assumes an intact environment, which is the assumption being violated when it runs), and
redacts token-shaped strings from the journal excerpt it forwards.

## Build Status

| Branch  | Status                                                                                                                                                                                                                                          |
|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| main    | [![Build: Pre-Release](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-pre-release.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-pre-release.yml) |
| release | [![Build: Release](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-release.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-release.yml)             |

### Development Container Builds

| Image                      | Status                                                                                                                                                                                                                                                               |
|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| development-tools          | [![Build: development-tools](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-tools.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-tools.yml)                            |
| development-node           | [![Build: development-node](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-node.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-node.yml)                               |
| development-python         | [![Build: development-python](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-python.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-python.yml)                         |
| development-dotnet-tools   | [![Build: development-dotnet-tools](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-dotnet-tools.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-dotnet-tools.yml)       |
| development-credfeto-tools | [![Build: development-credfeto-tools](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-credfeto-tools.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-credfeto-tools.yml) |
| development-full           | [![Build: development-full](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-full.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-full.yml)                               |
| development-agent          | [![Build: development-agent](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-agent.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-development-agent.yml)                            |

## Changelog

View [changelog](CHANGELOG.md)

## Documentation

Additional documentation is in the [docs/](docs/) folder:

- [Architecture](docs/architecture.md) — the map tying every subsystem doc together.
- [How `oneshot` works](docs/oneshot.md)
- [How the Workflow board works](docs/workflow-board.md)
- [How fingerprinting works](docs/fingerprinting.md)
- [How the agent container works](docs/agent-container.md)
- [How CodeGraph is set up and rolled out](docs/codegraph.md) - the agent container, workstations, repositories, agent definitions and shared instructions, with rollback.
- [How the base image chain works](docs/base-image-chain.md)
- [How GitHub integration works](docs/github-integration.md)
- [How Discord notifications work](docs/discord-notifications.md)
- [How deployment and setup work](docs/deployment-and-setup.md)
- [Development guide](docs/development/README.md) — how the scripts are written, tested and changed, with a guide for each script.

## Operational tasks

Re-runnable prompts for operating the live fleet are in the [tasks/](tasks/) folder:

- [Fleet health check](tasks/healthcheck.md) — paste into a Claude Code session to check both
  owners' services on `nanoclaw.lan` for wedged loops, unit failures, container-name orphans,
  host-resource problems and new permission denials. Tests for the *absence of expected
  success* as well as the presence of errors, because every failure that stops Claude starting
  also silences every Claude-derived signal.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines, the [development guide](docs/development/README.md) for how to change the code, and [SECURITY.md](SECURITY.md) for reporting security issues.

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

[discord-notifications]: docs/discord-notifications.md
