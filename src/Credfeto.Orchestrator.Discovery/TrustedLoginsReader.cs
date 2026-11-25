using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Discovery;

public sealed class TrustedLoginsReader : ITrustedLoginsReader
{
    private readonly IRetryDelay _delay;
    private readonly IGitHubReader _github;

    public TrustedLoginsReader(IGitHubReader github, IRetryDelay delay)
    {
        this._github = github;
        this._delay = delay;
    }

    public async ValueTask<string> ReadAsync(
        TrustedLoginsRequest request,
        RetryPolicy retry,
        CancellationToken cancellationToken
    )
    {
        IReadOnlyList<string> collaborators = await Retrying.RunAsync<IReadOnlyList<string>, GitHubReadException>(
            attempt: token =>
                this._github.RepositoryCollaboratorsAsync(repository: request.Repository, cancellationToken: token),
            policy: retry,
            delay: this._delay,
            cancellationToken: cancellationToken
        );

        return TrustedLogins.Build(
            owner: request.Owner,
            collaborators: collaborators,
            whitelist: request.Whitelist,
            creator: request.Creator
        );
    }
}
