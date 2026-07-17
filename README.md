# credfeto-orchestrator

Orchestrator tooling for driving Claude Code agents to work on GitHub issues and pull requests.

## oneshot

The `oneshot` script fetches the top-priority open work item for `credfeto/credfeto-orchestrator`
from the [priorities API](https://git-workflow.markridgwell.com/priorities) and invokes a
Claude Code session to work on it.  One session file is stored per issue or pull request at
`$HOME/.orchestrator/credfeto/credfeto-orchestrator/<ItemType>_<id>.env` so that subsequent
runs resume the correct Claude session.  When a PR has no session of its own the script
inherits the session from any linked closing issue.

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

- An issue or PR is **picked up** (new session started or existing session resumed), with a link to the item.
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

If either key is absent, `gh` falls back to its own `~/.config/gh/hosts.yml` configuration.

### Discord notifications (`DISCORD_WEBHOOK`)

To enable, add a `DISCORD_WEBHOOK` entry:

```dotenv
DISCORD_WEBHOOK=https://discord.com/api/webhooks/<id>/<token>
```

If `DISCORD_WEBHOOK` is absent or the file does not exist, Discord notifications are silently skipped.

## Build Status

| Branch  | Status                                                                                                                                                                                                                                          |
|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| main    | [![Build: Pre-Release](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-pre-release.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-pre-release.yml) |
| release | [![Build: Release](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-release.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-release.yml)             |

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [SECURITY.md](SECURITY.md) for reporting security issues.

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
