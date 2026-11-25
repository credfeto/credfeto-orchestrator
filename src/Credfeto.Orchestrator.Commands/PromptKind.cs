namespace Credfeto.Orchestrator.Commands;

public enum PromptKind
{
    ISSUE_CLAUDE_MD,
    PULL_REQUEST_CLAUDE_MD,
    ISSUE_LAUNCH,
    PULL_REQUEST_LAUNCH,
    PRECHECK_SECTION,
    CHECK_LENGTH,
}
