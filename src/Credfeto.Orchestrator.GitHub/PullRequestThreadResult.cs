using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// One inline review thread as pr_comments gives it: the file it is on and every comment in it
[DebuggerDisplay("{Path}")]
internal sealed record PullRequestThreadResult(string? Path, IReadOnlyList<PullRequestCommentResult?>? Comments);
