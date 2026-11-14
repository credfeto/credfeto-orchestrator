using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

public sealed class GitHubReaderTests : TestBase
{
    [Fact]
    public async Task OpenPullRequestsAreAskedOfPrListAndReturnedNewestFirstAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """{"pullRequests":[{"number":3,"flags":["fork"]},{"number":40},{"number":12}]}""",
            error: null
        );

        IReadOnlyList<int> numbers = await new GitHubReader(tools).OpenPullRequestsOnHeadAsync(
            repository: "org/repo",
            head: "fix/7-typo",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: [40, 12, 3], actual: numbers);
        Assert.Equal(expected: "pr_list", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["head"] = "fix/7-typo",
            },
            actual: tools.Arguments
        );
    }

    [Fact]
    public async Task NoOpenPullRequestIsAnEmptyListAsync()
    {
        IReadOnlyList<int> numbers = await ReadPullRequestsAsync(
            result: """{"repository":"org/repo","pullRequests":[]}""",
            cancellationToken: this.CancellationToken()
        );

        Assert.Empty(numbers);
    }

    [Theory]
    [InlineData("""{"repository":"org/repo"}""")]
    [InlineData("""{"pullRequests":null}""")]
    [InlineData("""{"pullRequests":[null]}""")]
    [InlineData("""{"pullRequests":[{"head":"main"}]}""")]
    [InlineData("""{"pullRequests":[{"number":0}]}""")]
    [InlineData("""{"pullRequests":[{"number":-4}]}""")]
    [InlineData("null")]
    public async Task APullRequestListInAnotherShapeIsAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            ReadPullRequestsAsync(result: result, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(
            expected: "the cfwf MCP server's pr_list result is not in the expected shape",
            actual: exception.Message
        );
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("""{"pullRequests":[{"number":"7"}]}""")]
    public async Task APullRequestListThatIsNotValidJsonIsAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            ReadPullRequestsAsync(result: result, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(expected: "the cfwf MCP server's pr_list result is not valid JSON", actual: exception.Message);
    }

    [Theory]
    [InlineData("""{"repo":"org/repo","branch":"main","checks":["build","test"]}""", true)]
    [InlineData("""{"repo":"org/repo","branch":"main","checks":[]}""", false)]
    public async Task ABranchRequiresChecksWhenTheServerListsAnyAsync(string result, bool expected)
    {
        FakeMcpToolCaller tools = new(result: result, error: null);

        bool required = await new GitHubReader(tools).BranchRequiresStatusChecksAsync(
            repository: "org/repo",
            branch: "release/1.0",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: expected, actual: required);
        Assert.Equal(expected: "branch_required_checks", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["branch"] = "release/1.0",
            },
            actual: tools.Arguments
        );
    }

    [Theory]
    [InlineData("""{"repo":"org/repo"}""")]
    [InlineData("""{"checks":null}""")]
    [InlineData("""{"checks":[null]}""")]
    [InlineData("""{"checks":["build",""]}""")]
    public async Task RequiredChecksInAnotherShapeAreAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .BranchRequiresStatusChecksAsync(
                    repository: "org/repo",
                    branch: "main",
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's branch_required_checks result is not in the expected shape",
            actual: exception.Message
        );
    }

    [Fact]
    public async Task AFailedToolCallIsPassedOnAsync()
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: null, error: "could not read"))
                .BranchRequiresStatusChecksAsync(
                    repository: "org/repo",
                    branch: "main",
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(expected: "could not read", actual: exception.Message);
    }

    private static Task<IReadOnlyList<int>> ReadPullRequestsAsync(
        string result,
        CancellationToken cancellationToken
    )
    {
        return new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
            .OpenPullRequestsOnHeadAsync(repository: "org/repo", head: "main", cancellationToken: cancellationToken)
            .AsTask();
    }
}
