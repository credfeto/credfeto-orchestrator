namespace Credfeto.Orchestrator.Predicates;

// The lib/github-status routing reads and the lib/workflow-board label reads `checks` answers
public enum ChecksQuery
{
    NEXT_PHASE,
    MERGE_STATE_ALLOWS_SETTLED,
    SESSION_PROGRESS_REASON,
    CLEAN_REVIEW_COMMENT,
    HAS_BLOCKED_LABEL,
    PRIORITY_FOR_LABELS,
}
