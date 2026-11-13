namespace Credfeto.Orchestrator.Jq;

// Declared in jq's sort order: null < false < true < numbers < strings < arrays < objects
public enum JqKind
{
    NULL,
    FALSE,
    TRUE,
    NUMBER,
    TEXT,
    ARRAY,
    DICTIONARY,
}
