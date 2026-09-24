# Development Guides

[Back to Local Instructions Index](index.md)

> Load when: changing any script, `lib/*` module, Claude Code hook or `*.bats` test in this repository, or adding a script.

## The guides

- The development guide for this repository is [docs/development/README.md](../../docs/development/README.md): what is where, how the shell scripts are written and tested, the change workflow, and the GitHub API behaviour that has caught us out (reads lagging writes, no single-item read in `gh project`, paging caps).
- Each script has its own guide under [docs/development/scripts/](../../docs/development/scripts/), named after the script (`oneshot`, `loop`, `interactive`, `create-project`, `setup-owner`, `install-timer`, `uninstall-timer`, `install-claude-hooks`, `notify-unit-failure`, `cfwf`, `pre-commit-check`, `querydb`).
- The `lib/*` function libraries are covered by [docs/development/lib.md](../../docs/development/lib.md) and the Claude Code hooks and permission files by [docs/development/claude-hooks.md](../../docs/development/claude-hooks.md).

## Rules

- Before changing a script, read the development guide and that script's guide. Before changing a `lib/*` module, read `lib.md`; before changing a hook, the allowlist or `claude-settings.json`, read `claude-hooks.md`.
- Update the guide in the same PR as any change to what the script does, how it is run, what it depends on, or how it is tested. A guide that no longer matches the code is a bug in the PR that made it stale.
- A new script needs its guide, added to the list in `docs/development/README.md`, in the same PR. `test/development-guides.bats` fails when a script has no guide or a link in `docs/development/` is broken.
- New agent-facing rules go in `ai/local`, not in the guides; the guides describe how the code works and how to change it, and link to the instruction files that hold the rules.
