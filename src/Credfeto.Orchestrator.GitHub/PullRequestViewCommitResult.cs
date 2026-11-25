using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

[DebuggerDisplay("{Oid}")]
internal sealed record PullRequestViewCommitResult(string? Oid, IReadOnlyList<CommitAuthorResult?>? Authors);
