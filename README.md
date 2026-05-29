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

### Per-owner API key

By default the script uses whatever `ANTHROPIC_API_KEY` is already set in the environment.
To charge Claude usage to a specific owner's Anthropic account, create a key file for that owner.

**Preferred location (XDG):**

```text
~/.config/orchestrator/api-keys/<owner>
```

**Legacy fallback location:**

```text
~/.orchestrator/<owner>/api-key
```

The file should contain the raw API key; any surrounding whitespace is stripped automatically.
The key is scoped to the `claude` invocation and is never written to log output.

**File permissions — set `600` to prevent other users from reading the key:**

```sh
chmod 600 ~/.config/orchestrator/api-keys/<owner>
```

Example — storing a key for the `credfeto` owner:

```sh
mkdir -p ~/.config/orchestrator/api-keys
printf '%s' 'sk-ant-...' > ~/.config/orchestrator/api-keys/credfeto
chmod 600 ~/.config/orchestrator/api-keys/credfeto
```

If neither key file exists, the script falls back to `ANTHROPIC_API_KEY` from the environment,
preserving the existing behaviour for installations that do not require per-owner billing.

## Build Status

| Branch  | Status                                                                                                                                                                                                                                          |
|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| main    | [![Build: Pre-Release](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-pre-release.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-pre-release.yml) |
| release | [![Build: Release](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-release.yml/badge.svg)](https://github.com/credfeto/credfeto-orchestrator/actions/workflows/build-and-publish-release.yml)             |

## Changelog

View [changelog](CHANGELOG.md)

## Documentation

Additional documentation is in the [docs/](docs/) folder.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [SECURITY.md](SECURITY.md) for reporting security issues.

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
