namespace Credfeto.Orchestrator.Podman;

// The session-outcome text heuristics of lib/podman, which read a message on stdin
public enum PodmanTextQuery
{
    BACKGROUND_STALL,
    DIAGNOSTIC_REFUSAL,
    TOOL_DENIED_QUIT,
    REVIEW_RESULT_MARKER,
    CLEAN_REVIEW,
}
