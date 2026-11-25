using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// Login is empty when the author's email is not linked to a GitHub account
[DebuggerDisplay("{Login} <{Email}>")]
internal sealed record CommitAuthorResult(string? Login, string? Email);
