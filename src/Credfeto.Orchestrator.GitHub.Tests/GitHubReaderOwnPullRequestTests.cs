using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

public sealed class GitHubReaderOwnPullRequestTests : TestBase
{
    private const string MIXED = """
        {"repository":"org/repo","pullRequests":[
          {"number":3,"author":"Bot-User","labels":[]},
          {"number":8,"author":"someone","labels":[]},
          {"number":12,"author":"app/prpixie","labels":["auto-pr","BLOCKED"]},
          {"number":20,"author":"app/PRPIXIE","labels":["auto-pr"]},
          {"number":31,"author":"app/dependabot","labels":["dependencies"]}
        ]}
        """;

    [Fact]
    public async Task OwnPullRequestsAreAskedOfPrListForTheWholeRepositoryAsync()
    {
        FakeMcpToolCaller tools = new(result: MIXED, error: null);

        IReadOnlyList<int> numbers = await new GitHubReader(tools).OwnOpenPullRequestsAsync(
            repository: "org/repo",
            me: "bot-user",
            creator: "app/prpixie",
            includeBlocked: false,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: [20, 3], actual: numbers);
        Assert.Equal(expected: "pr_list", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal) { ["repo"] = "org/repo" },
            actual: tools.Arguments
        );
    }

    [Fact]
    public async Task BlockedPullRequestsAreKeptWhenAskedForAsync()
    {
        IReadOnlyList<int> numbers = await ReadAsync(
            result: MIXED,
            includeBlocked: true,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: [20, 12, 3], actual: numbers);
    }

    [Fact]
    public async Task APullRequestWithNoAuthorIsNotOwnAsync()
    {
        IReadOnlyList<int> numbers = await ReadAsync(
            result: """{"pullRequests":[{"number":5,"author":"-","labels":[]}]}""",
            includeBlocked: false,
            cancellationToken: this.CancellationToken()
        );

        Assert.Empty(numbers);
    }

    [Theory]
    [InlineData("""{"repository":"org/repo"}""")]
    [InlineData("""{"pullRequests":[null]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"labels":[]}]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"author":"someone"}]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"author":"someone","labels":[null]}]}""")]
    [InlineData("""{"pullRequests":[{"number":0,"author":"bot-user","labels":[]}]}""")]
    public async Task AListInAnotherShapeIsAFailedReadEvenWhenNoEntryWouldBeKeptAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            ReadAsync(result: result, includeBlocked: false, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(
            expected: "the cfwf MCP server's pr_list result is not in the expected shape",
            actual: exception.Message
        );
    }

    private static Task<IReadOnlyList<int>> ReadAsync(
        string result,
        bool includeBlocked,
        CancellationToken cancellationToken
    )
    {
        return new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
            .OwnOpenPullRequestsAsync(
                repository: "org/repo",
                me: "bot-user",
                creator: "app/prpixie",
                includeBlocked: includeBlocked,
                cancellationToken: cancellationToken
            )
            .AsTask();
    }
}
