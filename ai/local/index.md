<!-- Globally Maintained -->
# Local instructions

This is an index of local instructions that apply to just this project.

* Ensure consistency across this file with respect to the global instructions.
* This file should be considered an index of local instructions.
* Each file other than this one should be named in the format `<category>.instructions.md` where `<category>` is the category of the file and all related rules should be listed there.
* `<category>.instructions.md` files should be placed in this directory.
* `<category>.instructions.md` files should maintain a backlink to this file.
* If this is the [git@github.com:credfeto/cs-template.git](https://github.com/credfeto/cs-template) repository, this folder should not have any other instructions than this file.
* This file should not be modified in [git@github.com:credfeto/cs-template.git](https://github.com/credfeto/cs-template), but can be modified in forks and other repositories as needed.
* The rules above this point in the file should be considered global rules.

## Instruction Files
<!-- Locally Maintained -->
* [Shell Testing](shell-testing.instructions.md) — bats-core test framework, oneshot's `lib/*` function-library layout and sourcing convention, the source-guard convention, test isolation, and external-command mocking for the `oneshot`, `loop`, `create-project`, `setup-owner`, and `install-timer` scripts. Load when working on those scripts, any `lib/*` file, or `test/*.bats`.
* [Docker Base Images](docker-images.instructions.md) — lock-down requirements, self-check mandates, ARG cache-busting pattern, workflow chain rules, and file placement conventions for `containers/base/` Dockerfiles.
* [Oneshot Prompts](oneshot-prompts.instructions.md) — prompt size limits, the `MAX_PROMPT_CHARS` guard, blocking-limit session-reset behaviour, and the rule that new agent guidance belongs in `cs-template` instruction files rather than in the bootstrap prompt. Load when working on `oneshot` or considering adding rules to `build_issue_prompt`/`build_pr_prompt`.
* [Debugging](debugging.instructions.md) — Headless-operation principle (any manual recovery = bug), mandatory SSH to `markr@nanoclaw.lan` for all diagnosis, state inventory (locks, fingerprints, sessions, containers, rate-limits, working dirs), and symptom-to-cause lookup table. Load when investigating orchestrator misbehaviour or a stalled/skipped work item.
* [Interactive Session](interactive-session.instructions.md) — Full lifecycle rule: interactive sessions must follow the same orchestrator workflow as non-interactive runs (plan → approve → implement → PR review loop → auto-merge). Always load at session start.
* [GitHub Projects v2](github-projects.instructions.md) — operational rules (test-one-first, verify-bot-access both ways), `create-project` script rules (`hasProjectsEnabled`, `|| exit 1` on die-calling substitutions), and GraphQL API correctness (correct collaborator type, union fragments, pagination, JSON-error-blob guard, `repositoryId` for repo-scoped projects, org vs personal). Load when working on `create-project` or `oneshot`'s `_wf_*` project-discovery functions.
* [Claude Hooks](claude-hooks.instructions.md) — `reject-obfuscated-commands`/`enforce-git-identity`/`enforce-git-dash-c`/`block-git-worktree` guardrail hooks: layered blocking policy, safe vs unsafe ways to extend them, and the tracking issue for allowlist requests needing human review. Load when a Bash hook blocks a command, or when working on `containers/base/development-full/claude-hooks/`.
