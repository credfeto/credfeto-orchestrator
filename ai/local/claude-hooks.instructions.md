<!-- Locally Maintained -->
# Claude Hooks

[Back to Local Instructions Index](index.md)

Local guardrail hooks live in `containers/base/development-full/claude-hooks/` and are wired into `~/.claude/settings.json` as `Bash` `PreToolUse` hooks, run in this order: `reject-obfuscated-commands`, `block-no-verify`, `enforce-git-identity`, `enforce-git-dash-c`, `block-git-worktree`, `block-dotnet-tool-install`, `enforce-ssh-scp-host-and-key`, `enforce-background-for-long-running-commands`.

## Prefer auto-correction over blocking, when it's a genuine correction

`PreToolUse` hooks can rewrite the tool call instead of only allowing/denying it, via `hookSpecificOutput.updatedInput` alongside `permissionDecision: "allow"` in the hook's JSON stdout (see Claude Code hooks documentation). When a blocked command has an unambiguous, safe rewrite available - one that fixes the actual problem rather than merely satisfying the check's syntax - prefer emitting that rewrite over blocking-and-retrying. It cuts a round trip without weakening the guardrail.

This is not a blanket instruction to auto-fix every block. A rewrite is only valid when it adds real information the hook can't already infer risk-free. It is not valid when the only available substitution would make the check pass without verifying anything - that's equivalent to not enforcing the check at all, just with extra steps. Concretely: `enforce-git-dash-c` stays block-only. The only value it could inject for a missing `-C <dir>` is the hook's own `$PWD`, which is exactly what plain `git` already defaults to when `-C` is omitted - so `git -C "$PWD" status` and bare `git status` behave identically. Auto-injecting it would make `-C` optional in practice for every command the settings.json deny-list doesn't separately cover, defeating the whole point of forcing the target repo to be explicit in the tool call. Before adding auto-correction to any hook, check whether the "fix" is actually a no-op like this one.

## reject-obfuscated-commands

Delegates parsing to `shfmt` and applies policy to the resulting AST rather than text-scanning. Blocks in layered order (all fail closed): non-ASCII/non-printable bytes anywhere in the command (after normalizing a small fixed table of known-benign Unicode punctuation - see below), unparseable shell, disallowed AST shapes (function defs, `declare`/`export`, non-literal command names), interpreters given an inline-code flag (`bash -c`, `python3 -c`, ...), `command-blocklist` names (`eval`, `sudo`, `env`, ...), then `command-allowlist` (anything not listed is rejected).

### Extending command-allowlist (MANDATORY process)

`command-allowlist` is a security control, not a convenience list - do not extend it unilaterally by default. When a command is blocked as "not on the known-good command allowlist":

* Default (including any autonomous/non-interactive run): do **not** edit `command-allowlist` yourself. Instead log the request in the tracking issue below - check its body and comments for the command name first and skip logging if it is already present, so requests do not get duplicated.
* Only edit `command-allowlist` directly when a human is present in the session and explicitly asks for that specific command to be added now. Still run the `reject-obfuscated-commands.bats` suite afterwards and commit/push per the normal workflow.

### Keep command-allowlist and claude-settings.json in sync

Enforced by `test/command-allowlist-parity.bats` on every PR (added after this exact drift shipped once - see `command-allowlist`'s own header comment for why the two files are separate layers in the first place): every `command-allowlist` name needs at least one matching `Bash(<name> ...)` entry in `claude-settings.json`'s `permissions.allow` - a blanket `Bash(<name> *)`, or one or more narrower subcommand-scoped patterns (as `git`/`gh`/`dotnet`/`bun`/`npm` deliberately use, on purpose, as least-privilege) - or CI fails. Whenever `command-allowlist` gains or loses a command, add or remove the matching entry in the same change - don't rely on the test to catch it after the fact; a tool missing an allow entry has no effect today (the container always passes `--dangerously-skip-permissions`) but would newly fall to the permission classifier, with no way to answer an "ask" in this unattended `--print` pipeline, the moment that flag is ever removed. Two exceptions the test also encodes:

* A name present in `command-allowlist` but also on `command-blocklist` (blocklist wins - e.g. `xargs`) is not actually usable and must **not** get a `claude-settings.json` allow entry; that would misrepresent it as permitted.
* A name with a *whole-command* deny in `claude-settings.json`'s own `permissions.deny` - `Bash(<name>)` or `Bash(<name> *)`, e.g. `sqlcmd` (denied to prevent reading `.database` credential files) - must not also get an allow entry for the same reason, even though `deny` already wins over `allow` for that specific pattern - a contradictory pair of entries is misleading regardless of which one takes effect. This does **not** apply to a narrow, args-scoped deny like `Bash(git config --add *)`: `git` still needs (and has) its own allow entries for its other, permitted invocations.

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

Runs before `enforce-background-for-long-running-commands`. Blocks `dotnet tool install` (local or global — any flag combination) and `dotnet new tool-manifest`. This container's .NET global tools are pinned and baked into the image at build time (see the "dotnet tools" sanity check in `containers/base/development-full/Dockerfile`, which asserts an exact set of tool names via `dotnet tool list -g`); either command would add an unpinned, unreviewed tool outside that set, bypassing the dependency-selection review the pinned set went through. Other `dotnet tool` subcommands (`list`/`restore`/`uninstall`/`update`/`run`/`search`) and other `dotnet new` templates remain allowed. Uses the same shfmt-parsed AST approach as `block-git-worktree`/`enforce-git-dash-c` and fails closed the same way. No safe auto-correct: there's no pinned-tool substitute the hook could infer and inject on the agent's behalf - adding a new pinned tool is a reviewed image-build change, not something a command rewrite can do.

## enforce-ssh-scp-host-and-key

Runs after `block-dotnet-tool-install`, before `enforce-background-for-long-running-commands`. Restricts `ssh`/`scp` to two conditions, added because `claude-settings.json`'s `Bash(ssh *)`/`Bash(scp *)` allow entries are blanket - the danger both tools pose is in the *destination*, not the verb, which a `permissions.allow` prefix pattern cannot scope (see [issue #1315](https://github.com/credfeto/credfeto-orchestrator/issues/1315)):

* **Host allowlist**: the target host must end in the `.lan` private-network suffix (e.g. `dns-01.lan`, `dns-01.dns.lan`), checked for both ssh's `[user@]host` form and scp's `[user@]host:path`/`scp://[user@]host[/path]` forms. `-o`/`-F`/`-J` (both tools) and `-D`/`-L`/`-R`/`-W`/`-w` (ssh only) are blocked outright rather than parsed, since each can redirect the connection or open a tunnel to a host this hook cannot see in the positional target argument (arbitrary config override, a jump host, a forwarded port to an arbitrary destination) - the same "cannot classify as safe, block outright" treatment `enforce-git-dash-c` gives `git config --file`/`--blob`.
* **Key precondition**: a usable SSH key must be loaded in the forwarded ssh-agent (`ssh-add -l` exits 0 against `SSH_AUTH_SOCK`) before a call that resolves an actual target host is allowed - this container never mounts raw private key files (agent-socket forwarding only), so a call can never silently fall back to interactive password auth. Checked lazily, only once a target is actually resolved, so a target-less call like `ssh -V` is left alone.

Uses the same shfmt-parsed AST approach as `enforce-git-dash-c`/`block-git-worktree`/`block-dotnet-tool-install` and fails closed the same way (missing `shfmt`, unparseable command, a non-literal target argument, or an unrecognised flag all block). No safe auto-correct: neither condition has a rewrite the hook could inject on the agent's behalf - a wrong host or a missing key are facts about the world, not something a command edit can fix.

`gpg` is deliberately **not** on `command-allowlist`/`permissions.allow` at all (removed alongside this hook, also from #1315): the agent's own Bash tool has no legitimate reason to invoke it directly - commit signing goes through git's own internal `gpg` invocation (`user.signingkey`/`commit.gpgsign`), and the only direct `gpg` calls in this repo are the `enforce-git-identity` hook's own subprocess check and `entrypoint.sh`'s container-startup validation, neither of which is gated by `permissions.allow` in the first place.

## enforce-background-for-long-running-commands

Runs last in the chain. Enforces the `credfeto-long-running-commands` rule that `git commit` (whose `pre-commit` hook run has no bounded duration), a directly-invoked `pre-commit`, `dotnet build`, `dotnet test`, `npm test`, and `bun test` must always be run with `run_in_background: true` on the Bash tool call. If `run_in_background` is `true`, allows immediately with no further check; a Bash call that omits the field entirely (the common case when a caller simply forgets it) is treated the same as an explicit `false` - it blocks. Otherwise parses the command with the same shfmt AST approach as `enforce-git-dash-c`/`block-git-worktree`/`block-dotnet-tool-install` and blocks if `git`/`.../git` in the command-name position (after skipping any `-c <k>=<v>`/`-C <dir>` pairs) is followed by subcommand `commit`, or `pre-commit`/`.../pre-commit` appears directly in the command-name position, or `dotnet`/`.../dotnet` is followed by `build` or `test`, or `npm`/`.../npm` or `bun`/`.../bun` is followed by `test`. Fails closed if `shfmt` is missing or the command doesn't parse. No safe auto-correct: the hook cannot inject `run_in_background: true` itself - that field lives in the tool call the hook is inspecting, not in the command string it could rewrite.

### Tracking allowlist requests

Every allowlist-block is logged in [credfeto/credfeto-orchestrator#1167](https://github.com/credfeto/credfeto-orchestrator/issues/1167) (labelled `Blocked`, `never-close`) for human review, unless a human in-session already approved and applied that specific addition (see above). Before logging a new request there, check the issue body and comments for the command name first - do not create duplicate entries.
