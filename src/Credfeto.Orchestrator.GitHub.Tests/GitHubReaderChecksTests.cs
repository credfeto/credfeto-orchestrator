using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

// The CI-check reads: a pull request's checks with GitHub's required flag, and the running check runs on a commit
public sealed class GitHubReaderChecksTests : TestBase
{
    private const string SHA = "0123456789abcdef0123456789abcdef01234567";

    [Fact]
    public async Task TheChecksAreAskedOfPrViewWithExactNamesAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """
            {"pr":"org/repo#7","checks":[
              {"kind":"check-run","name":"build\nline","status":"COMPLETED","conclusion":"SUCCESS","state":"","required":true},
              {"kind":"status","name":"ci/legacy","status":"","conclusion":"","state":"PENDING","required":false}
            ]}
            """,
            error: null
        );

        IReadOnlyList<PullRequestCheck> checks = await new GitHubReader(tools).PullRequestChecksAsync(
            repository: "org/repo",
            pullRequest: 7,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: [new PullRequestCheck(Name: "build\nline", Required: true), new("ci/legacy", Required: false)],
            actual: checks
        );
        Assert.Equal(expected: "pr_view", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["pr"] = "7",
                ["fields"] = "[\"checks\"]",
                ["exactCheckNames"] = "true",
            },
            actual: tools.Arguments
        );
    }

    [Fact]
    public async Task ACheckWithoutARequiredFlagIsAnOutdatedServerAsync()
    {
        McpServerOutdatedException exception = await Assert.ThrowsAsync<McpServerOutdatedException>(() =>
            new GitHubReader(
                new FakeMcpToolCaller(
                    result: """{"checks":[{"name":"build","required":true},{"name":"lint"}]}""",
                    error: null
                )
            )
                .PullRequestChecksAsync(
                    repository: "org/repo",
                    pullRequest: 7,
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's pr_view checks carry no required flag",
            actual: exception.Message
        );
    }

    [Theory]
    [InlineData("""{"pr":"org/repo#7"}""")]
    [InlineData("""{"checks":[null]}""")]
    [InlineData("""{"checks":[{"required":true}]}""")]
    [InlineData("""{"checks":[{"name":null,"required":true}]}""")]
    public async Task ChecksInAnotherShapeAreAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .PullRequestChecksAsync(
                    repository: "org/repo",
                    pullRequest: 7,
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's pr_view result is not in the expected shape",
            actual: exception.Message
        );
    }

    [Fact]
    public async Task TheRunningCountIsAskedOfCommitCheckRunsOnceTheServerListsItAsync()
    {
        FakeMcpToolCaller tools = new(
            result: "{\"repo\":\"org/repo\",\"sha\":\"" + SHA + "\",\"running\":2,\"checkRuns\":[]}",
            error: null
        );

        int running = await new GitHubReader(tools).CommitRunningCheckRunsAsync(
            repository: "org/repo",
            sha: SHA,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 2, actual: running);
        Assert.Equal(expected: 1, actual: tools.ToolLists);
        Assert.Equal(expected: "commit_check_runs", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal) { ["repo"] = "org/repo", ["sha"] = SHA },
            actual: tools.Arguments
        );
    }

    [Fact]
    public async Task AServerThatDoesNotListCommitCheckRunsIsOutdatedAndNotAskedAsync()
    {
        FakeMcpToolCaller tools = new(result: "{\"running\":1}", error: null, tools: ["pr_view", "pr_checks"]);

        McpServerOutdatedException exception = await Assert.ThrowsAsync<McpServerOutdatedException>(() =>
            new GitHubReader(tools)
                .CommitRunningCheckRunsAsync(
                    repository: "org/repo",
                    sha: SHA,
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(expected: "the cfwf MCP server does not list commit_check_runs", actual: exception.Message);
        Assert.Null(tools.Tool);
    }

    [Fact]
    public async Task AToolListThatFailsIsAFailedReadAsync()
    {
        FakeMcpToolCaller tools = new(result: "{\"running\":1}", error: null, toolsError: "connection refused");

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(tools)
                .CommitRunningCheckRunsAsync(
                    repository: "org/repo",
                    sha: SHA,
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(expected: "connection refused", actual: exception.Message);
        Assert.Null(tools.Tool);
    }

    [Theory]
    [InlineData("""{"repo":"org/repo"}""")]
    [InlineData("""{"running":-1}""")]
    [InlineData("""{"running":null}""")]
    public async Task ARunningCountInAnotherShapeIsAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .CommitRunningCheckRunsAsync(
                    repository: "org/repo",
                    sha: SHA,
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's commit_check_runs result is not in the expected shape",
            actual: exception.Message
        );
    }
}
