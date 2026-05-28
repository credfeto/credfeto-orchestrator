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
