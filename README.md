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

## interactive

The `interactive` script runs a live, attached Claude Code session inside the same locked-down
agent container that `oneshot` uses (see [docs/agent-container.md](docs/agent-container.md)),
against the git checkout containing your current directory. It is the developer-machine
counterpart to the unattended timer: same image, mounts, resource limits, GPG/SSH wiring and
baked-in permission settings, but with your terminal attached and no fixed work item.

### Running a session

```sh
cd ~/work/personal/some-repo
~/work/personal/credfeto-orchestrator/interactive
```

The repository must have a GitHub `origin` remote (its owner picks the Claude token and the
state directory). Your `cs-template` checkout is mounted read-only at `/workspace/rules`; it is
read from `$HOME/work/personal/cs-template` unless `INTERACTIVE_RULES_DIR` says otherwise, and
should be on `main`. Scratch space is a fresh directory under `$XDG_RUNTIME_DIR`, mounted at
`/workspace/tmp` and removed when the session ends. Persistent Claude state (sessions, plans,
cache) is shared with `oneshot` under `$HOME/.orchestrator/<owner>/<repo>`.

Like `oneshot`, every launch pulls `ORCHESTRATOR_IMAGE` first so the session runs the current
agent image; when the registry is unreachable the cached local image is used instead.

### First run

On the first run, `interactive` creates `$XDG_CONFIG_HOME/orchestrator/` (default
`~/.config/orchestrator/`, mode `700`) for you:

- `.env` is written from `git config --global user.name`, `user.email` and `user.signingkey`
  (the agent container GPG-signs every commit, so an SSH-format signing key is rejected). When
  `GH_HOST` points at a `gh` proxy, `GH_HOST` and the host's `gh auth token` are written too so
  `gh` inside the container is authenticated the same way it is on the host.
- `tokens/<owner>` (mode `600`) is created by running `claude setup-token`, which walks you
  through a browser sign-in and prints a long-lived token; paste it when prompted. The token
  from `~/.claude/.credentials.json` is deliberately not used: it expires within hours and
  cannot be refreshed from inside the container.

Existing files are never rewritten; edit them by hand.

### What the host needs

- `podman`
- `git`, `jq`, `gh` (authenticated)
- `claude` (Claude Code CLI) on the host, for `claude setup-token`
- a running `gpg-agent` holding the signing key, and an `ssh-agent` with a GitHub key loaded

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

## Operational tasks

Re-runnable prompts for operating the live fleet are in the [tasks/](tasks/) folder:

- [Fleet health check](tasks/healthcheck.md) — paste into a Claude Code session to check both
  owners' services on `nanoclaw.lan` for wedged loops, unit failures, container-name orphans,
  host-resource problems and new permission denials. Tests for the *absence of expected
  success* as well as the presence of errors, because every failure that stops Claude starting
  also silences every Claude-derived signal.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [SECURITY.md](SECURITY.md) for reporting security issues.

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
