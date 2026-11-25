using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// One issue a pull request closes, as the cfwf MCP server's pr_list and pr_view give it
[DebuggerDisplay("{Repository}#{Number}")]
internal sealed record ClosingIssueResult(string? Repository, int Number);
