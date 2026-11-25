using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// One top-level or inline comment as pr_comments gives it: Id is GitHub's numeric id as text, Author the login,
// "app/<slug>" for a GitHub App, "<type>/<login>" for another kind of account, or empty for a deleted account
[DebuggerDisplay("{Id}: {Author}")]
internal sealed record PullRequestCommentResult(
    string? Id,
    string? Author,
    string? Body,
    string? CreatedAt,
    string? UpdatedAt
);
