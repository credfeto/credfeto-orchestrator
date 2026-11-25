using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// Every top-level comment and every inline review comment on a pull request, each in GitHub's id order
[DebuggerDisplay("Comments={Comments.Count}, ReviewComments={ReviewComments.Count}")]
public sealed record PullRequestComments(
    IReadOnlyList<PullRequestComment> Comments,
    IReadOnlyList<PullRequestReviewComment> ReviewComments
);
