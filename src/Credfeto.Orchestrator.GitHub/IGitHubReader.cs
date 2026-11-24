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

    // The numbers of the open pull requests the orchestrator itself opened (authored by me or by the pull request bot,
    // creator, compared case-insensitively), leaving out those labelled Blocked unless includeBlocked, newest first as
    // list_bot_created_open_prs prints them
    ValueTask<IReadOnlyList<int>> OwnOpenPullRequestsAsync(
        string repository,
        string me,
        string creator,
        bool includeBlocked,
        CancellationToken cancellationToken
    );
}
