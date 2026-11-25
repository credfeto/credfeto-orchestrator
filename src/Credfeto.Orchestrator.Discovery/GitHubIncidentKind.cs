namespace Credfeto.Orchestrator.Discovery;

// github_incident_open's return codes
public enum GitHubIncidentKind
{
    // 0: a serious incident on a used component, so the tick is skipped
    SERIOUS,

    // 3: only minor incidents on used components, so the tick carries on with a warning
    MINOR,

    // 1: no unresolved incident on a used component
    NONE,

    // 2: the status could not be read, which callers treat as healthy (fail open)
    UNREADABLE,
}
