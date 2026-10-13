# Issue Title Instructions

[Back to Local Instructions Index](index.md)

> Load when: creating or renaming an issue in this repository, or opening a pull request for one.

## Format (MANDATORY)

Every issue title in this repository has the form `<scope>: <rest>`, where `<scope>` names the tool or component the issue affects, so the issue list shows each issue's component at a glance and is easy to filter.

This rule overrides an issue title format given in any other instruction, because local rules take precedence over global ones.

An issue title that code, a workflow or an action files and finds again by exact title match is exempt from this format and must never be renamed by hand, because a rename makes the lookup miss and a duplicate gets filed. Change the title where it is defined instead, and leave it alone when that definition is maintained in another repository, because the next sync would overwrite the change. Examples are `RATE_LIMIT_ISSUE_TITLE` and `WF_SETUP_ISSUE_TITLE` in `lib/globals`, and `chore: update GitHub Actions version pins`, which is set as `issueTitle` in `.github/actions/check-composite-action-versions/action.yml` and is left alone, because that action is maintained in `cs-template` and synced from there.

This applies to issue titles only. Pull request titles keep the Conventional Commits format, and a pull request's Conventional Commits type comes from the change itself, never from the issue's scope, because a scope is not a Conventional Commits type.

## Choosing the scope

- **Top-level scripts**, meaning each executable script at the repository root, use their bare name, for example `oneshot`, `loop` or `create-project`. `lib/*` and its prompt text count as `oneshot`, unless the problem only shows through another script, in which case use that script's scope, because several scripts source the shared modules.
- **Scripts under `containers/base/development-full/scripts/`** use `tool(<name>)`, for example `tool(cfwf)`, `tool(pre-commit-check)` or `tool(querydb)`.
- **Hooks** use `hook(<name>)` for one hook, and `hooks` for several hooks or the hook framework. A hook's data files under `containers/base/development-full/claude-hooks/` (`command-allowlist`, `command-blocklist`, `allowed-dirs`, `env-var-blocklist`) take the hook scope.
- **Containers** use `container(<image>)` for one image, and `containers` for several.
- **Claude configuration** uses `claude(settings)` for `claude-settings.json` and `claude-policy-limits.json`, including a change to `permissions.allow`, and `claude(permissions)` only for a standing tracker issue that collects denied commands over time. An issue that asks to allow, block or fix one specific command follows the tie-break below, because it is not a tracker.
- **Task files** use `task(<name>)` for `tasks/<name>.md`.
- **Agents** use `agents` for agent role and instruction behaviour, including the instruction files under `ai/`.
- **Documentation** uses `docs` for `docs/` and the README.
- **Everything else** uses `tests` for bats-only work, `ci` for everything under `.github/`, and `repo` for repo-wide tooling, lint or baseline and anything not listed above.

A new script, image, hook or task gets its scope under the same rules, without any change to this file.

When more than one of the hook, Claude configuration and container scopes fits, as with an issue about one specific blocked command, use the scope of the file the fix will change, or the most likely one when that is not yet known, so one topic is not split across scopes. This does not apply to `lib/*`, which follows its own rule above and takes the scope where the problem shows.

## The rest of the title

- Do not add a Conventional Commits type (`fix:`, `feat:`, `test:`, `chore:` and so on), even in a combined form such as `fix(oneshot):`, or a `Security:` prefix, because the title says where the problem is and a label says what kind it is. The scopes `docs`, `ci` and `tests` are chosen by the rules above and are allowed as the title's scope, even though `docs` and `ci` are also Conventional Commits type names, because what is banned is a type added on top of the scope or instead of it. Add the matching label when one fits: `Bug`, `Enhancement`, `Refactor`, `Tech Debt`, `Security` or `Performance`.
- Do not add `Design:` or `Track:` as a prefix either, but keep the word in the text, for example `Track requests ...` or `... (design)`, because no label carries it.
- Drop a leading tool name that the scope makes redundant.
- Capitalise the first word after the scope, for example `tool(cfwf): List a repository's open issues with labels`, unless it is a code identifier, flag, file name or path, which keeps its own case.
