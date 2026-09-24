# create-project

Idempotently provisions the "Workflow" GitHub Project (v2) board for one repository so the orchestrator can drive it.

Back to the [development guide](../README.md).

## Purpose

`create-project` makes sure a repository has a project titled "Workflow", linked to the repository, carrying a "Workflow Status" single-select field with the orchestrator's ten statuses, and with the orchestrator bot (`BOT_LOGIN`, `dnyw4l3n13`) granted WRITER access. It is run by hand, once per repository, by the human repository owner: the script's header explains that only the owner can create a project under a personal account, so it must not be run as the bot. `docs/deployment-and-setup.md` lists it as step 3 of onboarding an owner, and `docs/workflow-board.md` explains why `oneshot` needs the board.

## Running it

```bash
create-project --repo <owner>/<repo> [--force-bootstrap]
```

- `--repo` (required) must match `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`.
- `--force-bootstrap` re-runs board seeding on an already-provisioned project. Without it, seeding only happens when this run created the project.
- Anything else dies with `Unknown argument`; a missing or empty `--repo` value dies with `--repo requires a value`.

Environment variables: the script reads none of its own. The bot login, project title and field name are hard-coded assignments (`BOT_LOGIN`, `PROJECT_TITLE`, `STATUS_FIELD_NAME`) and are not overridable. `gh` itself uses whatever authentication and host settings (for example `GH_HOST`) are in the caller's environment; which token scopes are needed is not checked by the script.

Inputs and outputs: it reads and writes only through `gh` (GraphQL, `gh repo view`, `gh repo edit`, `gh issue list`, `gh pr list`); it touches no local files apart from a temporary stderr capture file inside `gh_graphql`. Progress goes to stdout through `info` and `success`, warnings to stderr through `warn`.

Exit codes: 0 on success, including when granting the bot access fails (that only warns) and, because of the swallowed dies described under Gotchas, when the status field cannot be created or updated. A `die` that is not swallowed exits 1. There is no other non-zero code.

## How it works

The script sources `lib/core` (`die`, `success`, `info`, `warn`) with a `BASH_SOURCE`-based path and a fatal fallback. It then defines its own `check_required_tools`, which replaces the one in `lib/core` and requires only `gh` and `jq`. The main flow is `main` then `provision_project`:

1. `main` parses arguments, validates `--repo`, calls `check_required_tools`.
2. `resolve_repo_node_id` looks up the repository's GraphQL node ID.
3. `ensure_projects_enabled` reads `hasProjectsEnabled` and runs `gh repo edit --enable-projects` when it is not `true`.
4. `discover_linked_project` queries `repository.projectsV2` and picks the project titled "Workflow". If found, create and link are skipped.
5. Otherwise `resolve_owner_node_id` (organisation query, then user query) and `create_project` (`createProjectV2` with `repositoryId`, which also links the project) run, and the run is marked as created.
6. `ensure_status_field` creates the field with all ten options, or, if present, calls `ensure_status_field_option` for "AI Simplify" (after "Development") and "AI Coverage" (after "AI Security Review"). It sets the globals `WF_FIELD_ID` and `WF_NOT_STARTED_OPT`.
7. `ensure_project_description` sets the short description to `Workflow for <owner>/<repo>` unless already correct.
8. `ensure_bot_collaborator` resolves the bot's node ID and calls `updateProjectV2Collaborators` with role WRITER; both failure paths only warn.
9. If the project was just created or `--force-bootstrap` was given, `bootstrap_board_items` adds every open issue and PR and sets each to "Not Started".

External tools: `gh`, `jq`, plus `head`, `tr`, `sed`, `awk`, `wc`, `mktemp`, `rm`, `dirname` and `basename` (not checked). The header comment lists four steps and omits the description and Projects-enabled steps that the code also performs.

## Tests

`test/create-project.bats` loads `test_helper`, calls `setup_isolated_env` and `source_create_project` in `setup()`, and calls `cleanup_stubs` in `teardown()`. Because the script has a source guard, sourcing it defines the functions without running `main`, and tests call `main`, `provision_project` and the helpers directly.

`gh` is faked by `install_gh_stub`, which uses `make_stub` to write a PATH stub. The stub is one `case` on the joined argument string. It returns an already `--jq`-filtered value, so the jq filters passed to `gh` are not exercised by the suite. It appends each mutation name to `CREATE_PROJECT_GH_LOG` and each `--input` body to `CREATE_PROJECT_GH_INPUT_LOG`, and tests grep those logs. Knobs are `DISCOVERY_RESULT`, `PROJECT_SHORT_DESC`, `PROJECTS_ENABLED`, `BOOT_ISSUE_IDS`, `BOOT_PR_IDS`, `FIELD_CREATE_RESULT` and `FIELD_OPTION_UPDATE_RESULT`. Smaller tests such as "bootstrap_board_items dies when gh issue list fails" define a one-off stub with `make_stub gh`. "check_required_tools dies when gh is missing" overrides the `command` builtin with a shell function.

Unusual points: the stub's `case` patterns are order-sensitive (for example `*updateProjectV2ItemFieldValue*` must precede `*updateProjectV2*`, and `*createProjectV2Field*` must precede `*createProjectV2*`); the stub answers `*user*` with `U_NODE`, which also serves the bot lookup; `jq` is the real binary.

Run just this file with `bats test/create-project.bats`, or one test with `bats -f "seeds open issues" test/create-project.bats`.

## Changing it safely

- Run `shellcheck create-project` and keep it clean.
- Run `bats test/create-project.bats`.
- Mutation-check each new test: break the code it covers and confirm the test fails, then restore it. The stub returns canned answers, so a test can pass without proving anything.
- Update `docs/deployment-and-setup.md`, `docs/workflow-board.md`, `ai/local/github-projects.instructions.md` and `README.md` if behaviour they describe changes.
- Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- The pre-commit hooks run the whole bats suite, so commits and pushes take minutes; run them in the background.

## Gotchas

- There is no `set -e`, `set -u` or `pipefail`. Functions that call `die` inside `$(...)` lose the exit; callers write `|| exit 1` (see `provision_project` and `ai/local/github-projects.instructions.md`). `ensure_projects_enabled` is called without a substitution so its `die` works. `ensure_status_field` is also called directly (it communicates through the globals `WF_FIELD_ID` and `WF_NOT_STARTED_OPT`), but inside it `field_node=$(ensure_status_field_option ...)` and `resp=$(gh_graphql ...)` are unguarded substitutions with no `|| exit 1`. A failed field-create or option-update mutation is therefore swallowed: the script carries on with an empty field ID, prints "Status field added" after a failed create, and can still exit 0. Only `bootstrap_board_items` notices, and only when seeding runs. This breaks the `|| exit 1` rule in `ai/local/github-projects.instructions.md`. It is existing behaviour, not something this guide changes.
- `resolve_owner_node_id` guards against `gh api graphql --jq` printing a raw JSON error body (`[[ "${id}" == \{* ]]`).
- Discovery is scoped to the repository, so a "Workflow" project that exists but is not linked to it is not found and a second one is created.
- `discover_linked_project` asks for `projectsV2(first:20)` and `fields(first:30)` with no pagination. A repository with more than 20 linked projects could hide the Workflow project. This is read from the query, not tested.
- On an existing field only "AI Simplify" and "AI Coverage" are migrated; other missing options are not added. `ensure_status_field_option` re-sends every existing option with its `id` so item values survive, and inserts the new option after a named option or appends it.
- `ensure_projects_enabled` treats a failed read as "not enabled" (`|| true`) and then tries to enable Projects.
- GitHub API lag: a listing can trail a write by seconds to minutes. The script never reads back after a write: it takes IDs from mutation responses, and `ensure_status_field_option` feeds its returned field JSON into the next call. It has no wait or retry, so a re-run straight after a create could fail to discover the new project through `projectsV2` and create another. That risk is inferred from the code, not observed.
- `gh project` and its lack of a single-item read do not apply: the script uses `gh api graphql` and never reads one item.
- Seeding uses `gh issue list` and `gh pr list` with `--limit 1001`. `gh` pages 100 items per request and stops at the limit, so the extra item lets the script detect more than 1000 and warn, then trim to 1000. These list results can lag, so an item created moments before the run may be missed and is not retried.
- `--force-bootstrap` sets every open item to "Not Started" through `updateProjectV2ItemFieldValue` without checking its current status, despite the header's remark about human-curated items. Whether `addProjectV2ItemById` returns the existing item for content already on the board is GitHub behaviour this repository does not test.
