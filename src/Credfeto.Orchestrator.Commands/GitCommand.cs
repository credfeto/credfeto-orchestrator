using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// Repository is the directory git runs in (git -C, so empty means the current directory); Name is the branch for
// origin-branch-exists, the ref for commits-behind and the issue number for stale-issue-branch
[DebuggerDisplay("Query={Query}, Repository={Repository}, Name={Name}")]
public sealed record GitCommand(GitQuery Query, string Repository, string Name = "", string Upstream = "");
