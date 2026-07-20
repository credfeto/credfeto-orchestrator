<!-- Locally Maintained -->
# Claude Hooks

[Back to Local Instructions Index](index.md)

Local guardrail hooks live in `containers/base/development-full/claude-hooks/` and are wired into `~/.claude/settings.json` as `Bash` `PreToolUse` hooks, run in this order: `reject-obfuscated-commands`, `block-no-verify`, `enforce-git-identity`, `enforce-git-dash-c`, `block-git-worktree`, `block-dotnet-tool-install`.

## Prefer auto-correction over blocking, when it's a genuine correction

`PreToolUse` hooks can rewrite the tool call instead of only allowing/denying it, via `hookSpecificOutput.updatedInput` alongside `permissionDecision: "allow"` in the hook's JSON stdout (see Claude Code hooks documentation). When a blocked command has an unambiguous, safe rewrite available - one that fixes the actual problem rather than merely satisfying the check's syntax - prefer emitting that rewrite over blocking-and-retrying. It cuts a round trip without weakening the guardrail.

This is not a blanket instruction to auto-fix every block. A rewrite is only valid when it adds real information the hook can't already infer risk-free. It is not valid when the only available substitution would make the check pass without verifying anything - that's equivalent to not enforcing the check at all, just with extra steps. Concretely: `enforce-git-dash-c` stays block-only. The only value it could inject for a missing `-C <dir>` is the hook's own `$PWD`, which is exactly what plain `git` already defaults to when `-C` is omitted - so `git -C "$PWD" status` and bare `git status` behave identically. Auto-injecting it would make `-C` optional in practice for every command the settings.json deny-list doesn't separately cover, defeating the whole point of forcing the target repo to be explicit in the tool call. Before adding auto-correction to any hook, check whether the "fix" is actually a no-op like this one.

## reject-obfuscated-commands

Delegates parsing to `shfmt` and applies policy to the resulting AST rather than text-scanning. Blocks in layered order (all fail closed): non-ASCII/non-printable bytes anywhere in the command (after normalizing a small fixed table of known-benign Unicode punctuation - see below), unparseable shell, disallowed AST shapes (function defs, `declare`/`export`, non-literal command names), interpreters given an inline-code flag (`bash -c`, `python3 -c`, ...), `command-blocklist` names (`eval`, `sudo`, `env`, ...), then `command-allowlist` (anything not listed is rejected).

### Extending command-allowlist (MANDATORY process)

`command-allowlist` is a security control, not a convenience list - do not extend it unilaterally by default. When a command is blocked as "not on the known-good command allowlist":

* Default (including any autonomous/non-interactive run): do **not** edit `command-allowlist` yourself. Instead log the request in the tracking issue below - check its body and comments for the command name first and skip logging if it is already present, so requests do not get duplicated.
* Only edit `command-allowlist` directly when a human is present in the session and explicitly asks for that specific command to be added now. Still run the `reject-obfuscated-commands.bats` suite afterwards and commit/push per the normal workflow.

### Non-ASCII / Layer 0 block

Do **not** loosen the "reject any non-ASCII byte" check - it is a deliberate, hardened defence (8 code-review rounds; see the script's own header comment) against Unicode homoglyph/zero-width/bidi-override obfuscation, not an allowlist gap.

The hook itself now auto-corrects the common case: a small, fixed substitution table (em dash/en dash to hyphen, curly single/double quotes to straight quotes, non-breaking space to space, right/left arrow to `->`/`<-`, ellipsis to `...`) is applied before the ASCII check, and if that alone makes the command fully ASCII and it clears every other layer, the hook returns the normalized command via `hookSpecificOutput.updatedInput` instead of blocking - see [Prefer auto-correction over blocking](#prefer-auto-correction-over-blocking-when-its-a-genuine-correction) above. This was verified empirically against the live multi-hook `PreToolUse` chain (not just unit-tested against the script), since the chain runs hooks in parallel and the docs don't specify how competing decisions merge: a throwaway probe hook confirmed a rewrite from one hook in the chain does reach actual execution even when the other hooks in the same matcher return no decision.

This cannot loosen the check: the table is fixed, small, and applied unconditionally; anything left non-ASCII afterwards (control bytes, real homoglyphs, zero-width/bidi-override characters, or any character not in the table) still blocks exactly as before. When a command is blocked for this reason (i.e. normalization didn't fully resolve it):

* First choice: rewrite the command text in plain ASCII - this covers cases the fixed table doesn't (e.g. non-ASCII content that has to stay non-ASCII, or an editor-inserted character not on the list).
* If the content genuinely needs Unicode (e.g. an issue/PR body): write it to a file with the `Write` tool (not subject to this Bash hook) and pass it via a `--body-file`/equivalent flag so the actual Bash command line stays pure ASCII.

## enforce-git-identity

Runs after `block-no-verify`, before `enforce-git-dash-c`. Blocks git subcommands that create/rewrite commits, plus `fetch` (checked up front so a broken identity is caught before work starts, not after) - `commit`/`fetch`/`pull`/`rebase`/`merge`/`cherry-pick`/`revert`/`am` - unless git identity and GPG signing are correctly configured (`user.email` set and not the banned identity, `commit.gpgsign` true, a GPG secret key present for that email, `user.signingkey` set and matching a keyring entry for that email). No safe auto-correct: the problem is missing/misconfigured system state (git config, GPG keyring), not a fixable command string - nothing in the command text can be rewritten to make a signing key exist.

## enforce-git-dash-c

Parses each Bash command with `shfmt` and blocks any `git` invocation (including `sudo git ...` and other known wrapper prefixes) that isn't hardened with `git -C <dir>`. Also blocks `eval`/`source`/`.` outright, since their argument is a second command line this hook cannot verify. Fails closed if `shfmt` is missing or the command doesn't parse. No safe auto-correct - see [Prefer auto-correction over blocking](#prefer-auto-correction-over-blocking-when-its-a-genuine-correction) above.

## block-git-worktree

Runs after `enforce-git-dash-c`. Blocks `git worktree add` (creating a new linked worktree) — a linked worktree splits repo state across multiple checkouts sharing one object store and one set of refs, which does not compose with this project's assumption of one checkout per repo directory. An errant `git worktree add` previously left a primary checkout registered as bare with no work tree of its own, breaking `git pull`/`git status` there until it was manually repaired. Other worktree subcommands (`list`/`remove`/`prune`/`lock`/`unlock`/`move`/`repair`/...) are inspection or cleanup of worktrees that already exist and remain allowed. Uses the same shfmt-parsed AST approach as `enforce-git-dash-c` and fails closed the same way. No safe auto-correct: `add` is a categorical policy block, not a syntax mistake, and there's no equivalent allowed command to substitute - the suggested alternative (a normal branch checkout) requires the agent to choose a branch name/target itself.

## block-dotnet-tool-install

Runs last in the chain. Blocks `dotnet tool install` (local or global — any flag combination) and `dotnet new tool-manifest`. This container's .NET global tools are pinned and baked into the image at build time (see the "dotnet tools" sanity check in `containers/base/development-full/Dockerfile`, which asserts an exact set of tool names via `dotnet tool list -g`); either command would add an unpinned, unreviewed tool outside that set, bypassing the dependency-selection review the pinned set went through. Other `dotnet tool` subcommands (`list`/`restore`/`uninstall`/`update`/`run`/`search`) and other `dotnet new` templates remain allowed. Uses the same shfmt-parsed AST approach as `block-git-worktree`/`enforce-git-dash-c` and fails closed the same way. No safe auto-correct: there's no pinned-tool substitute the hook could infer and inject on the agent's behalf - adding a new pinned tool is a reviewed image-build change, not something a command rewrite can do.

### Tracking allowlist requests

Every allowlist-block is logged in [credfeto/credfeto-orchestrator#1167](https://github.com/credfeto/credfeto-orchestrator/issues/1167) (labelled `Blocked`, `never-close`) for human review, unless a human in-session already approved and applied that specific addition (see above). Before logging a new request there, check the issue body and comments for the command name first - do not create duplicate entries.
