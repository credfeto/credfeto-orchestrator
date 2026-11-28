using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's commit_check_runs result the read uses: how many check runs on the commit have no
// conclusion and a queued, in_progress, waiting, pending or requested status; null when it is missing
[DebuggerDisplay("Running={Running}")]
internal sealed record CommitCheckRunsResult(int? Running);
