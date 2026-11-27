using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of one pr_view checks entry the required check read uses; Required is null when the server gives none, as
// a server older than workflow-mcp #188 does
[DebuggerDisplay("{Name}: Required={Required}")]
internal sealed record PullRequestCheckResult(string? Name, bool? Required);
