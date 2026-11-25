namespace Credfeto.Orchestrator.Git;

public enum StaleBranchMatch
{
    NO_MATCH,
    MATCH,

    // Bash decides it by the locale: a non-ASCII character where the regex is still looking
    LOCALE_DEPENDENT,
}
