# Issue Title Instructions

[Back to Local Instructions Index](index.md)

> Load when: creating or renaming an issue in this repository.

## Format (MANDATORY)

Every issue title in this repository has the form `<scope>: <rest>`, where `<scope>` names the tool or component the issue affects. The scope shows at a glance which component an issue affects, and makes the issue list easy to filter.

This applies to issue titles only. Pull request titles keep the Conventional Commits format.

## Choosing the scope

- **Top-level scripts** use their bare name: `oneshot`, `interactive`, `loop`, `create-project`, `setup-owner`, `install-timer`, `uninstall-timer`, `install-claude-hooks`, `notify-unit-failure`. `lib/*` and its prompt text count as `oneshot`.
- **Scripts under `containers/base/development-full/scripts/`** use `tool(<name>)`, for example `tool(cfwf)`, `tool(pre-commit-check)` or `tool(querydb)`.
- **Hooks** use `hook(<name>)` for one hook, and `hooks` for several hooks or the hook framework.
- **Containers** use `container(<image>)` for one image, and `containers` for several.
- **Claude configuration** uses `claude(settings)` for `claude-settings.json`, and `claude(permissions)` for permission-mode and denial tracking.
- **Task files** use `task(<name>)` for `tasks/<name>.md`.
- **Agents** use `agents` for agent role and instruction behaviour.
- **Everything else** uses `tests` for bats-only work, `ci` for `.github/workflows`, and `repo` for repo-wide tooling, lint or baseline.

A new script, image, hook or task gets its scope under the same rules, without any change to this file.

## The rest of the title

- Do not add a Conventional Commits type (`fix:`, `feat:`, `test:`, `chore:` and so on) or a category word (`Security:`, `Design:`, `Track:`), because labels already carry them. Use the scope alone, never a combined form such as `fix(oneshot):`.
- Drop a leading tool name that the scope makes redundant.
- Capitalise the first word after the scope, for example `tool(cfwf): List a repository's open issues with labels`.
