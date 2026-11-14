using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// Name is the head branch for the pull request reads and the branch for the status check read
[DebuggerDisplay("Read={Read}, Repository={Repository}, Name={Name}")]
public sealed record GitHubCommand(GitHubRead Read, string Repository, string Name);
