using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's branch_compare result the read uses; BehindBy is null when it is missing
[DebuggerDisplay("BehindBy={BehindBy}")]
internal sealed record BranchCompareResult(int? BehindBy);
