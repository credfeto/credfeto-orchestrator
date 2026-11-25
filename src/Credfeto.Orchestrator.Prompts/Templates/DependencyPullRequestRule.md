<!-- markdownlint-disable-file -->
DEPENDENCY PR RULE (MANDATORY): this is a dependency PR, so follow this rule:
- It is already yours. The orchestrator only gives you a dependency PR that is unassigned, assigned to you, or assigned only to trusted maintainers, and each of those makes it this automation's own.
- Do NOT run any assign or claim step. Never pass --assign-self to any cfwf command, and never add, remove or change an assignee of this PR or of any issue in any way. This overrides every "assign yourself" step in the AI instructions (the task workflow and the PR Submitter role included) and applies to every sub-agent you start, so tell each one.
{{comments_step}}
{{then_step}}
