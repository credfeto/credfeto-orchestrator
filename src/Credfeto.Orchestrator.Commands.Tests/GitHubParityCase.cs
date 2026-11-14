using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands.Tests;

// Name is the head or base branch the read names; McpResult is the tool's result text, or McpError its failure
[DebuggerDisplay("Case={Case}, Expected={Expected}")]
public sealed record GitHubParityCase(
    string Case,
    string Repository,
    string Name,
    string? McpResult,
    string? McpError,
    string? Expected
);
