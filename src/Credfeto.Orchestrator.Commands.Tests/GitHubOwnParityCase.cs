using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands.Tests;

// An ownOpenPullRequests case: the logins and Blocked choice list_bot_created_open_prs is given, and McpResult the
// tool's result text, or McpError its failure
[DebuggerDisplay("Case={Case}, Expected={Expected}")]
public sealed record GitHubOwnParityCase(
    string Case,
    string Repository,
    string Me,
    string Creator,
    string IncludeBlocked,
    string? McpResult,
    string? McpError,
    string? Expected
);
