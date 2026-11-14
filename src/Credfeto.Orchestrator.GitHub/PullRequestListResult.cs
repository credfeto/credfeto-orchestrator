using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's pr_list result the read uses; every other property is ignored
[DebuggerDisplay("PullRequests={PullRequests}")]
internal sealed record PullRequestListResult(IReadOnlyList<PullRequestListResultEntry?>? PullRequests);
