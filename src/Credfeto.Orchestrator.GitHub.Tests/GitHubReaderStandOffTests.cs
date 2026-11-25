using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

// The reads the issue stand-off and the bot-driven pull request pivot make
public sealed class GitHubReaderStandOffTests : TestBase
{
    [Fact]
    public async Task TheCurrentLoginIsAskedOfAuthStatusAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """{"login":"bot-user","host":"mcp.example.test","version":"2022-11-28"}""",
            error: null
        );

        string login = await new GitHubReader(tools).CurrentLoginAsync(this.CancellationToken());

        Assert.Equal(expected: "bot-user", actual: login);
        Assert.Equal(expected: "auth_status", actual: tools.Tool);
        Assert.Empty(tools.Arguments ?? throw new InvalidOperationException("no call"));
    }

    [Theory]
    [InlineData("""{"host":"mcp.example.test"}""")]
    [InlineData("""{"login":null}""")]
    [InlineData("null")]
    public async Task AnAuthStatusWithoutALoginIsAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .CurrentLoginAsync(this.CancellationToken())
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's auth_status result is not in the expected shape",
            actual: exception.Message
        );
    }

    [Fact]
    public async Task OpenPullRequestsWithClosingIssuesAreAskedOfPrListNewestFirstAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """
            {"repository":"org/repo","pullRequests":[
              {"number":3,"head":"fix/3-a","author":"-","labels":[],"closingIssues":[]},
              {"number":40,"head":"feat/9-b","author":"app/prpixie","labels":["auto-pr"],
               "closingIssues":[{"repository":"org/repo","number":9},{"repository":"org/other","number":2}]},
              {"number":12,"head":"main","author":"Someone","labels":[],"closingIssues":[]}
            ]}
            """,
            error: null
        );

        IReadOnlyList<OpenPullRequestReferences> pullRequests = await new GitHubReader(
            tools
        ).OpenPullRequestsWithClosingIssuesAsync(repository: "org/repo", cancellationToken: this.CancellationToken());

        Assert.Equal(expected: [40, 12, 3], actual: pullRequests.Select(pullRequest => pullRequest.Number));
        Assert.Equal(expected: "app/prpixie", actual: pullRequests[0].Author);
        Assert.Equal(expected: [9, 2], actual: pullRequests[0].ClosingIssues);
        Assert.Equal(expected: "feat/9-b", actual: pullRequests[0].Head);
        Assert.Equal(expected: "Someone", actual: pullRequests[1].Author);
        Assert.Equal(expected: string.Empty, actual: pullRequests[2].Author);
        Assert.Empty(pullRequests[2].ClosingIssues);
        Assert.Equal(expected: "pr_list", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["closingIssues"] = "true",
            },
            actual: tools.Arguments
        );
    }

    [Theory]
    [InlineData("""{"repository":"org/repo"}""")]
    [InlineData("""{"pullRequests":[null]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"head":"main","author":"a","labels":[]}]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"author":"a","labels":[],"closingIssues":[]}]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"head":"main","labels":[],"closingIssues":[]}]}""")]
    [InlineData("""{"pullRequests":[{"number":0,"head":"main","author":"a","labels":[],"closingIssues":[]}]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"head":"main","author":"a","closingIssues":[null]}]}""")]
    [InlineData("""{"pullRequests":[{"number":4,"head":"m","author":"a","closingIssues":[{"number":0}]}]}""")]
    public async Task AClosingIssuesListInAnotherShapeIsAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .OpenPullRequestsWithClosingIssuesAsync(
                    repository: "org/repo",
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's pr_list result is not in the expected shape",
            actual: exception.Message
        );
    }

    [Fact]
    public async Task CommitAuthorsAreAskedOfPrViewForTheCommitsFieldAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """
            {"pr":"org/repo#7","commits":[
              {"oid":"abc","authors":[
                {"login":"bot-user","email":"bot@example.test","name":"Bot"},
                {"login":"","email":"jo@example.test","name":"Jo"}
              ]},
              {"oid":"def","authors":[]}
            ]}
            """,
            error: null
        );

        IReadOnlyList<PullRequestCommit> commits = await new GitHubReader(tools).PullRequestCommitsAsync(
            repository: "org/repo",
            pullRequest: 7,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 2, actual: commits.Count);
        Assert.Equal(
            expected:
            [
                new CommitAuthor(Login: "bot-user", Email: "bot@example.test"),
                new(Login: string.Empty, Email: "jo@example.test"),
            ],
            actual: commits[0].Authors
        );
        Assert.Empty(commits[1].Authors);
        Assert.Equal(expected: "pr_view", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["pr"] = "7",
                ["fields"] = "[\"commits\"]",
            },
            actual: tools.Arguments
        );
    }

    [Theory]
    [InlineData("""{"pr":"org/repo#7"}""")]
    [InlineData("""{"commits":[null]}""")]
    [InlineData("""{"commits":[{"oid":"abc"}]}""")]
    [InlineData("""{"commits":[{"oid":"abc","authors":[null]}]}""")]
    [InlineData("""{"commits":[{"oid":"abc","authors":[{"email":"a@example.test"}]}]}""")]
    [InlineData("""{"commits":[{"oid":"abc","authors":[{"login":"a"}]}]}""")]
    public async Task CommitsInAnotherShapeAreAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .PullRequestCommitsAsync(
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

    [Theory]
    [InlineData("""{"status":"behind","aheadBy":0,"behindBy":3}""", 3)]
    [InlineData("""{"status":"identical","aheadBy":0,"behindBy":0}""", 0)]
    public async Task TheBehindByCountIsAskedOfBranchCompareAsync(string result, int expected)
    {
        FakeMcpToolCaller tools = new(result: result, error: null);

        int behindBy = await new GitHubReader(tools).BranchBehindByAsync(
            repository: "org/repo",
            baseBranch: "main",
            headBranch: "fix/7-typo",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: expected, actual: behindBy);
        Assert.Equal(expected: "branch_compare", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["base"] = "main",
                ["head"] = "fix/7-typo",
            },
            actual: tools.Arguments
        );
    }

    [Theory]
    [InlineData("""{"status":"behind"}""")]
    [InlineData("""{"behindBy":null}""")]
    [InlineData("""{"behindBy":-1}""")]
    public async Task ACompareWithoutABehindCountIsAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .BranchBehindByAsync(
                    repository: "org/repo",
                    baseBranch: "main",
                    headBranch: "fix/7-typo",
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's branch_compare result is not in the expected shape",
            actual: exception.Message
        );
    }
}
