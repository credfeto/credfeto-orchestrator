using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's pr_view result the reads use; every other property is ignored
[DebuggerDisplay("Commits={Commits}")]
internal sealed record PullRequestViewResult(IReadOnlyList<PullRequestViewCommitResult?>? Commits);
