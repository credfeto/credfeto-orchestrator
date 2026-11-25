using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// Name is the head branch for the pull request reads and the behind-by read, the branch for the status check read and
// the agent's own login for the own pull request read, which alone uses Creator (the pull request bot's login) and
// IncludeBlocked. Base is the base branch of the behind-by read and PullRequest the number of the commit authors read.
// The current login read uses neither Repository nor Name, which are then empty
[DebuggerDisplay("Read={Read}, Repository={Repository}, Name={Name}")]
public sealed record GitHubCommand(
    GitHubRead Read,
    string Repository,
    string Name,
    string? Creator = null,
    bool IncludeBlocked = false,
    string? Base = null,
    int PullRequest = 0
);
