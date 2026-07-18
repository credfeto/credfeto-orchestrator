<!-- Locally Maintained -->
# Claude Hooks

[Back to Local Instructions Index](index.md)

Local guardrail hooks live in `containers/base/development-full/claude-hooks/` and are wired into `~/.claude/settings.json` as `Bash` `PreToolUse` hooks, run in this order: `reject-obfuscated-commands`, `block-no-verify`, `enforce-git-identity`, `enforce-git-dash-c`, `block-git-worktree`, `block-dotnet-tool-install`.

## reject-obfuscated-commands

Delegates parsing to `shfmt` and applies policy to the resulting AST rather than text-scanning. Blocks in layered order (all fail closed): non-ASCII/non-printable bytes anywhere in the command, unparseable shell, disallowed AST shapes (function defs, `declare`/`export`, non-literal command names), interpreters given an inline-code flag (`bash -c`, `python3 -c`, ...), `command-blocklist` names (`eval`, `sudo`, `env`, ...), then `command-allowlist` (anything not listed is rejected).

### Extending command-allowlist (MANDATORY process)

`command-allowlist` is a security control, not a convenience list - do not extend it unilaterally by default. When a command is blocked as "not on the known-good command allowlist":

* Default (including any autonomous/non-interactive run): do **not** edit `command-allowlist` yourself. Instead log the request in the tracking issue below - check its body and comments for the command name first and skip logging if it is already present, so requests do not get duplicated.
* Only edit `command-allowlist` directly when a human is present in the session and explicitly asks for that specific command to be added now. Still run the `reject-obfuscated-commands.bats` suite afterwards and commit/push per the normal workflow.

### Non-ASCII / Layer 0 block

Do **not** loosen the "reject any non-ASCII byte" check - it is a deliberate, hardened defence (8 code-review rounds; see the script's own header comment) against Unicode homoglyph/zero-width/bidi-override obfuscation, not an allowlist gap. When a command is blocked for this reason:

* First choice: rewrite the command text in plain ASCII (em dash to hyphen, curly quotes to straight quotes, arrows to `->`, etc.) - this covers the large majority of cases, since the non-ASCII is usually gratuitous formatting in AI-authored text.
* If the content genuinely needs Unicode (e.g. an issue/PR body): write it to a file with the `Write` tool (not subject to this Bash hook) and pass it via a `--body-file`/equivalent flag so the actual Bash command line stays pure ASCII.

## enforce-git-dash-c

Parses each Bash command with `shfmt` and blocks any `git` invocation (including `sudo git ...` and other known wrapper prefixes) that isn't hardened with `git -C <dir>`. Also blocks `eval`/`source`/`.` outright, since their argument is a second command line this hook cannot verify. Fails closed if `shfmt` is missing or the command doesn't parse.

## block-git-worktree

Runs after `enforce-git-dash-c`. Blocks `git worktree add` (creating a new linked worktree) — a linked worktree splits repo state across multiple checkouts sharing one object store and one set of refs, which does not compose with this project's assumption of one checkout per repo directory. An errant `git worktree add` previously left a primary checkout registered as bare with no work tree of its own, breaking `git pull`/`git status` there until it was manually repaired. Other worktree subcommands (`list`/`remove`/`prune`/`lock`/`unlock`/`move`/`repair`/...) are inspection or cleanup of worktrees that already exist and remain allowed. Uses the same shfmt-parsed AST approach as `enforce-git-dash-c` and fails closed the same way.

## block-dotnet-tool-install

Runs last in the chain. Blocks `dotnet tool install` (local or global — any flag combination) and `dotnet new tool-manifest`. This container's .NET global tools are pinned and baked into the image at build time (see the "dotnet tools" sanity check in `containers/base/development-full/Dockerfile`, which asserts an exact set of tool names via `dotnet tool list -g`); either command would add an unpinned, unreviewed tool outside that set, bypassing the dependency-selection review the pinned set went through. Other `dotnet tool` subcommands (`list`/`restore`/`uninstall`/`update`/`run`/`search`) and other `dotnet new` templates remain allowed. Uses the same shfmt-parsed AST approach as `block-git-worktree`/`enforce-git-dash-c` and fails closed the same way.

### Tracking allowlist requests

Every allowlist-block is logged in [credfeto/credfeto-orchestrator#1167](https://github.com/credfeto/credfeto-orchestrator/issues/1167) (labelled `Blocked`, `never-close`) for human review, unless a human in-session already approved and applied that specific addition (see above). Before logging a new request there, check the issue body and comments for the command name first - do not create duplicate entries.
