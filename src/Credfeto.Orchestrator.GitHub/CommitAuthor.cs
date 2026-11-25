using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// Login is empty when GitHub has not linked the commit's email to an account
[DebuggerDisplay("{Login} <{Email}>")]
public sealed record CommitAuthor(string Login, string Email);
