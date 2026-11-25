namespace Credfeto.Orchestrator.Commands;

public enum GitQuery
{
    HEAD_SHA,
    CURRENT_BRANCH,
    UNCOMMITTED_CHANGES,
    ORIGIN_BRANCH_EXISTS,
    COMMITS_BEHIND,
    STALE_ISSUE_BRANCH,
}
