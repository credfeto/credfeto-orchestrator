using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Discovery.Tests;

// Fails the first failures collaborator reads, then answers with collaborators; the other reads are not used
internal sealed class FakeGitHubReader : IGitHubReader
{
    private readonly IReadOnlyList<string> _collaborators;
    private readonly int _failures;

    public FakeGitHubReader(int failures, params IReadOnlyList<string> collaborators)
    {
        this._failures = failures;
        this._collaborators = collaborators;
    }

    public int Reads { get; private set; }

    public string? Repository { get; private set; }

    public ValueTask<IReadOnlyList<string>> RepositoryCollaboratorsAsync(
        string repository,
        CancellationToken cancellationToken
    )
    {
        this.Reads++;
        this.Repository = repository;

        return this.Reads > this._failures
            ? ValueTask.FromResult(this._collaborators)
            : ValueTask.FromException<IReadOnlyList<string>>(new GitHubReadException("the server is down"));
    }

    public ValueTask<IReadOnlyList<int>> OpenPullRequestsOnHeadAsync(
        string repository,
        string head,
        CancellationToken cancellationToken
    )
    {
        throw new NotSupportedException();
    }

    public ValueTask<bool> BranchRequiresStatusChecksAsync(
        string repository,
        string branch,
        CancellationToken cancellationToken
    )
    {
        throw new NotSupportedException();
    }

    public ValueTask<IReadOnlyList<int>> OwnOpenPullRequestsAsync(
        string repository,
        string me,
        string creator,
        bool includeBlocked,
        CancellationToken cancellationToken
    )
    {
        throw new NotSupportedException();
    }
}
