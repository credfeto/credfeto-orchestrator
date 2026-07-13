<!-- Locally Maintained -->
# Claude Hooks

[Back to Local Instructions Index](index.md)

Local guardrail hooks live in `containers/base/development-full/claude-hooks/` and are wired into `~/.claude/settings.json` as `Bash` `PreToolUse` hooks (`enforce-git-dash-c`, `reject-obfuscated-commands`, `block-no-verify`).

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

### Tracking allowlist requests

Every allowlist-block is logged in [credfeto/credfeto-orchestrator#1167](https://github.com/credfeto/credfeto-orchestrator/issues/1167) (labelled `Blocked`, `never-close`) for human review, unless a human in-session already approved and applied that specific addition (see above). Before logging a new request there, check the issue body and comments for the command name first - do not create duplicate entries.
