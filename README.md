# credfeto-orchestrator

Orchestrator tooling for driving Claude Code agents to work on GitHub issues and pull requests.

## oneshot

The `oneshot` script fetches the top-priority open work item for `credfeto/credfeto-orchestrator`
from the [priorities API](https://git-workflow.markridgwell.com/priorities) and invokes a
Claude Code session to work on it.  Every run starts a fresh session and never resumes an
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
unproxied access set `GH_HOST=github.com` with a real token; it then reaches the container as
`GH_TOKEN` rather than `GH_ENTERPRISE_TOKEN`, which `gh` ignores for github.com.

### Discord notifications (`DISCORD_WEBHOOK`)

To enable, add a `DISCORD_WEBHOOK` entry:

```dotenv
DISCORD_WEBHOOK=https://discord.com/api/webhooks/<id>/<token>
```

If `DISCORD_WEBHOOK` is absent or the file does not exist, Discord notifications are silently skipped.

### Unit-failure alerts (`notify-unit-failure`)

`install-timer` also installs a `<service>-failure.service` unit, wired to the main service's
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
