using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// Name is the head branch for the pull request reads, the branch for the status check read and the agent's own login
// for the own pull request read, which alone uses Creator (the pull request bot's login) and IncludeBlocked
[DebuggerDisplay("Read={Read}, Repository={Repository}, Name={Name}")]
public sealed record GitHubCommand(
    GitHubRead Read,
    string Repository,
    string Name,
    string? Creator = null,
    bool IncludeBlocked = false
);
