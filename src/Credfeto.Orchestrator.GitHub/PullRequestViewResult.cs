using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's pr_view result the reads use; every other property is ignored. Each field is only
// present when it was asked for
[DebuggerDisplay("Commits={Commits}, ClosingIssues={ClosingIssues}, Checks={Checks}")]
internal sealed record PullRequestViewResult(
    IReadOnlyList<PullRequestViewCommitResult?>? Commits,
    IReadOnlyList<ClosingIssueResult?>? ClosingIssues = null,
    IReadOnlyList<PullRequestCheckResult?>? Checks = null
);
