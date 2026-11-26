namespace Credfeto.Orchestrator.Agents;

// Whether pkill -f's pattern matches a process's command line: MATCH and NO_MATCH are certain; UNCERTAIN means the
// answer depends on how procps renders a byte outside printable ASCII or on where an older procps cuts the text
public enum PkillMatch
{
    MATCH,
    NO_MATCH,
    UNCERTAIN,
}
