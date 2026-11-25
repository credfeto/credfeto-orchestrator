using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The author and co-authors of one commit on a pull request
[DebuggerDisplay("Authors={Authors.Count}")]
public sealed record PullRequestCommit(IReadOnlyList<CommitAuthor> Authors);
