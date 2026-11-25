using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's pr_comments result the comment reads use: the top-level comments and the inline
// review threads; every other property is ignored
[DebuggerDisplay("Comments={Comments}, Threads={Threads}")]
internal sealed record PullRequestCommentsResult(
    IReadOnlyList<PullRequestCommentResult?>? Comments,
    IReadOnlyList<PullRequestThreadResult?>? Threads
);
