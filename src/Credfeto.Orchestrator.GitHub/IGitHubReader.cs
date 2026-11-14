using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.GitHub;

public interface IGitHubReader
{
    // The numbers of the open pull requests whose head branch is exactly head, a fork's included, newest first as gh
    // pr list orders them
    ValueTask<IReadOnlyList<int>> OpenPullRequestsOnHeadAsync(
        string repository,
        string head,
        CancellationToken cancellationToken
    );

    // Whether the branch requires any status check, through classic branch protection or a ruleset
    ValueTask<bool> BranchRequiresStatusChecksAsync(
        string repository,
        string branch,
        CancellationToken cancellationToken
    );
}
