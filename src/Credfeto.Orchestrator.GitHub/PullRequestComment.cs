using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// A top-level pull request comment. Login is the author's login as GitHub's REST API gives it ("<slug>[bot]" for a
// GitHub App), or null when the account no longer exists
[DebuggerDisplay("{Id}: {Login}")]
public sealed record PullRequestComment(long Id, string? Login, string Body, string CreatedAt, string UpdatedAt);
