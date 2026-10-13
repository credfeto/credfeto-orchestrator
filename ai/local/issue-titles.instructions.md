# Issue Title Instructions

[Back to Local Instructions Index](index.md)

> Load when: creating or renaming an issue in this repository.

## Format (MANDATORY)

Every issue title in this repository has the form `<scope>: <rest>`, where `<scope>` names the tool or component the issue affects, so the issue list shows each issue's component at a glance and is easy to filter.

This rule overrides an issue title format given in any other instruction, because local rules take precedence over global ones.

An issue title that the code itself files and finds again by exact title match is exempt from this format and must never be renamed by hand, because a rename makes the lookup miss and a duplicate gets filed; change the constant in the code instead. The current cases are `RATE_LIMIT_ISSUE_TITLE` and `WF_SETUP_ISSUE_TITLE` in `lib/globals`.

This applies to issue titles only. Pull request titles keep the Conventional Commits format, and a pull request's Conventional Commits type comes from the change itself, never from the issue's scope, because a scope is not a Conventional Commits type.

## Choosing the scope

- **Top-level scripts** use their bare name: `oneshot`, `loop`, `create-project`, `setup-owner`, `install-timer`, `uninstall-timer`, `install-claude-hooks`, `notify-unit-failure`. `lib/*` and its prompt text count as `oneshot`, unless the problem only shows through another script, in which case use that script's scope, because several scripts source the shared modules.
- **Scripts under `containers/base/development-full/scripts/`** use `tool(<name>)`, for example `tool(cfwf)`, `tool(pre-commit-check)` or `tool(querydb)`.
- **Hooks** use `hook(<name>)` for one hook, and `hooks` for several hooks or the hook framework.
- **Containers** use `container(<image>)` for one image, and `containers` for several.
- **Claude configuration** uses `claude(settings)` for `claude-settings.json`, and `claude(permissions)` only for tracking denied commands.
- **Task files** use `task(<name>)` for `tasks/<name>.md`.
- **Agents** use `agents` for agent role and instruction behaviour, including the instruction files under `ai/`.
- **Documentation** uses `docs` for `docs/` and the README.
- **Everything else** uses `tests` for bats-only work, `ci` for everything under `.github/`, and `repo` for repo-wide tooling, lint or baseline and anything not listed above.

A new script, image, hook or task gets its scope under the same rules, without any change to this file.

When more than one scope fits, as with a blocked command that could be a hook, Claude configuration or container matter, use the scope of the file the fix will change, so one topic is not split across scopes.

## The rest of the title

- Do not add a Conventional Commits type (`fix:`, `feat:`, `test:`, `chore:` and so on), even in a combined form such as `fix(oneshot):`, or a `Security:` prefix, because labels already carry them.
- Do not add `Design:` or `Track:` as a prefix either, but keep the word in the text, for example `Track requests ...` or `... (design)`, because no label carries it.
- Drop a leading tool name that the scope makes redundant.
- Capitalise the first word after the scope, for example `tool(cfwf): List a repository's open issues with labels`, unless it is a code identifier, flag, file name or path, which keeps its own case.
