<!-- Locally Maintained -->
# Oneshot Prompt Instructions

[Back to Local Instructions Index](index.md)

> Load when: working on the `oneshot` script, or when considering whether to add new guidance for the orchestrator agent.

## Prompt Size Limits and Context Overflow

Claude Code enforces a hard context limit (`terminal_reason=blocking_limit`, surfaced as
"Prompt is too long"). This is NOT about the launch prompt — that is tiny — it is the whole
conversation (system prompt + generated CLAUDE.md + every tool result over many turns)
exceeding the model context window. The `oneshot` script is structured to prevent it:

1. **One phase per invocation (the real fix)** — every run is a FRESH session (there is no
   `--resume`). The generated CLAUDE.md instructs the agent to do exactly ONE workflow phase
   (setup / fix / a single `/code-review` round / a single `/security-review` round / finalize)
   and then STOP. Because a fresh session only ever holds one phase's worth of tool output, it
   cannot accumulate the 100+ turns that used to overflow the window. The orchestrator re-invokes
   the item on later ticks to advance through the remaining phases; all state that carries
   between phases lives in GitHub (branch, commits, PR comments, labels, Workflow board).

2. **`MAX_PROMPT_CHARS=100000`** — a pre-send sanity guard in `invoke_claude` that rejects the
   launch prompt if it somehow exceeds 100 000 characters. Generated prompts are well under 2 KB;
   this catches pathological cases only and is not the overflow defence.

3. **Runaway/idle guards** — a per-PR `<total> <idle>` invocation-guard file bounds re-invocation:
   `MAX_PR_TOTAL_INVOCATIONS` (default 30) marks a non-converging PR Blocked; `MAX_PR_IDLE_INVOCATIONS`
   (default 5) parks a PR whose fingerprint stops changing. See `debugging.instructions.md` §5.

If a fresh single-phase session still hits `blocking_limit`, one phase is genuinely too large to
fit — a human must split the work (the `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE` environment variable
can raise the limit at runtime as a stopgap).

## Where New Agent Rules Belong

**Do not extend `build_issue_prompt` or `build_pr_prompt` to add new guidance.**

Those functions produce a short, fixed bootstrap message (< 2 KB). They intentionally contain only the minimum needed to orient the agent to the specific work item — the issue/PR number, repo path, and a handful of GitHub CLI reminders. Adding rules here:

- inflates the prompt on every invocation, consuming context that the agent needs for actual work
- scatters governance rules across a shell script rather than a version-controlled instruction file
- makes the prompt harder to audit and maintain

**The correct place for new orchestrator rules is `cs-template`'s `ai/global/` or `ai/local/` instruction files**, specifically:

| What you want to add | File in cs-template |
| --- | --- |
| Agent role behaviour (what the Orchestrator/Code Writer/etc. does) | `ai/global/agent-roles.instructions.md` |
| Git workflow, branching, commit format | `ai/global/git.instructions.md` or `ai/global/git-commits.instructions.md` |
| Code quality, test, async, immutability | `ai/global/code-quality.instructions.md` |
| Error handling | `ai/global/error-handling.instructions.md` |
| Anything specific to this orchestrator repo | `ai/local/<category>.instructions.md` |

The agent reads `.ai-instructions` (which indexes those files) at the start of every session, so rules placed there are always loaded without consuming any of the bootstrap prompt budget.

## Prompt Content Guidelines

If something genuinely must be in the bootstrap prompt (e.g. a GitHub CLI quirk that must be stated before any tool call fires), keep it:

- **Specific** — one concrete instruction, not a policy essay
- **Actionable** — phrased as a command the agent can follow immediately
- **Non-duplicative** — if `agent-roles.instructions.md` already covers it, remove it from the prompt

Review `build_issue_prompt` and `build_pr_prompt` whenever adding a new rule. If an existing line is now covered by an instruction file, remove it from the prompt rather than leaving both.

## Dynamic Data in build_issue_claude_md and build_pr_claude_md

`build_issue_claude_md` and `build_pr_claude_md` embed **runtime data** that cannot live in instruction files because it is specific to the individual repo being processed:

| Data block | Source | Purpose |
| --- | --- | --- |
| Workflow board section (`WF_PROJECT_ID`, `WF_STATUS_FIELD_ID`, `WF_*` option IDs) | `_build_wf_section()` — populated by `discover_or_create_workflow_project` | Agent uses these to move the issue/PR through the Workflow board mid-session |

This is not policy — it is per-repo instance data that changes between runs. Do not move it to instruction files.

When `_WF_PROJECT_ID` is empty (project discovery failed or not configured), `_build_wf_section` emits nothing and the agent skips all board updates silently.
