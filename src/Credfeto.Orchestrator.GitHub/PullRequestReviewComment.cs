using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// An inline review comment on a file of a pull request. Login is as for PullRequestComment
[DebuggerDisplay("{Id}: {Login} on {Path}")]
public sealed record PullRequestReviewComment(long Id, string? Login, string Path, string Body, string UpdatedAt);
