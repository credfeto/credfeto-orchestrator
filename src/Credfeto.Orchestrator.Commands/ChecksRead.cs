namespace Credfeto.Orchestrator.Commands;

// The checks reads that ask GitHub, through the cfwf MCP server, rather than answering from their arguments
public enum ChecksRead
{
    REQUIRED_CHECK_NAMES,
    HAS_RUNNING_CHECK_RUNS,
}
