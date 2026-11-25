using System;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.GitHub;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class TrustedLoginsReaderTests : TestBase
{
    private static readonly TrustedLoginsRequest Request = new(
        Repository: "org/repo",
        Owner: "org",
        Whitelist: "friend",
        Creator: "prpixie"
    );

    private static readonly RetryPolicy ThreeAttempts = new(Attempts: 3, Delay: TimeSpan.FromSeconds(2));

    [Fact]
    public async Task TheCollaboratorsAreReadForTheRepositoryAndAddedAsync()
    {
        FakeGitHubReader github = new(0, "alice");
        FakeRetryDelay delay = new();

        string trusted = await ReadAsync(github: github, delay: delay, cancellationToken: this.CancellationToken());

        Assert.Equal(
            expected: "[\n  \"alice\",\n  \"copilot-pull-request-reviewer\",\n  \"friend\",\n"
                + "  \"github-advanced-security[bot]\",\n  \"org\"\n]",
            actual: trusted
        );
        Assert.Equal(expected: 1, actual: github.Reads);
        Assert.Equal(expected: "org/repo", actual: github.Repository);
        Assert.Empty(delay.Delays);
    }

    [Fact]
    public async Task AFailedReadIsRetriedAfterTheDelayAsync()
    {
        FakeGitHubReader github = new(2, "alice");
        FakeRetryDelay delay = new();

        await ReadAsync(github: github, delay: delay, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: 3, actual: github.Reads);
        Assert.Equal(expected: [TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2)], actual: delay.Delays);
    }

    [Fact]
    public async Task CollaboratorsThatAreNeverReadFailClosedAsync()
    {
        FakeGitHubReader github = new(3, "alice");
        FakeRetryDelay delay = new();

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            ReadAsync(github: github, delay: delay, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(expected: "the server is down", actual: exception.Message);
        Assert.Equal(expected: 3, actual: github.Reads);
        Assert.Equal(expected: 2, actual: delay.Delays.Count);
    }

    private static async Task<string> ReadAsync(
        FakeGitHubReader github,
        FakeRetryDelay delay,
        CancellationToken cancellationToken
    )
    {
        return await new TrustedLoginsReader(github: github, delay: delay).ReadAsync(
            request: Request,
            retry: ThreeAttempts,
            cancellationToken: cancellationToken
        );
    }
}
