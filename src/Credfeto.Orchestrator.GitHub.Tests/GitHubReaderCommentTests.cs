using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

// The reads behind a pull request's comment, closing issue and closing issue label lookups
public sealed class GitHubReaderCommentTests : TestBase
{
    private const string COMMENT = """
        {"id":"5","author":"owner","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-02T10:00:00Z","body":"x"}
        """;

    [Fact]
    public async Task CommentsAreAskedOfPrCommentsWithExactBodiesInIdOrderAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """
            {"pr":"org/repo#7","comments":[
              {"id":"20","author":"app/prpixie","createdAt":"c2","updatedAt":"u2","body":"Done\n"},
              {"id":"3","author":"","createdAt":"c1","updatedAt":"u1","body":"Gone"}
             ],
             "threads":[
              {"path":"src/a.cs","comments":[
                {"id":"100","author":"owner","createdAt":"c","updatedAt":"u3","body":"First"},
                {"id":"300","author":"enterpriseuseraccount/someone","createdAt":"c","updatedAt":"u5","body":"Reply"}
              ]},
              {"path":"lib/b","comments":[
                {"id":"200","author":"reviewer","createdAt":"c","updatedAt":"u4","body":"Why"}
              ]}
             ]}
            """,
            error: null
        );

        PullRequestComments comments = await new GitHubReader(tools).PullRequestCommentsAsync(
            repository: "org/repo",
            pullRequest: 7,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected:
            [
                new PullRequestComment(Id: 3, Login: null, Body: "Gone", CreatedAt: "c1", UpdatedAt: "u1"),
                new PullRequestComment(Id: 20, Login: "prpixie[bot]", Body: "Done\n", CreatedAt: "c2", UpdatedAt: "u2"),
            ],
            actual: comments.Comments
        );
        Assert.Equal(
            expected:
            [
                new PullRequestReviewComment(Id: 100, Login: "owner", Path: "src/a.cs", Body: "First", UpdatedAt: "u3"),
                new PullRequestReviewComment(Id: 200, Login: "reviewer", Path: "lib/b", Body: "Why", UpdatedAt: "u4"),
                new PullRequestReviewComment(
                    Id: 300,
                    Login: "someone",
                    Path: "src/a.cs",
                    Body: "Reply",
                    UpdatedAt: "u5"
                ),
            ],
            actual: comments.ReviewComments
        );
        Assert.Equal(expected: "pr_comments", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["pr"] = "7",
                ["exactBodies"] = "true",
            },
            actual: tools.Arguments
        );
    }

    [Theory]
    [InlineData("""{"threads":[]}""")]
    [InlineData("""{"comments":[]}""")]
    [InlineData("""{"comments":[null],"threads":[]}""")]
    [InlineData("""{"comments":[{"id":"5","createdAt":"c","updatedAt":"u","body":"x"}],"threads":[]}""")]
    [InlineData("""{"comments":[{"id":"5","author":"a","updatedAt":"u","body":"x"}],"threads":[]}""")]
    [InlineData("""{"comments":[{"id":"5","author":"a","createdAt":"c","body":"x"}],"threads":[]}""")]
    [InlineData("""{"comments":[{"id":"5","author":"a","createdAt":"c","updatedAt":"u"}],"threads":[]}""")]
    [InlineData("""{"comments":[{"author":"a","createdAt":"c","updatedAt":"u","body":"x"}],"threads":[]}""")]
    [InlineData("""{"comments":[{"id":"0","author":"a","createdAt":"c","updatedAt":"u","body":"x"}],"threads":[]}""")]
    [InlineData("""{"comments":[{"id":"-5","author":"a","createdAt":"c","updatedAt":"u","body":"x"}],"threads":[]}""")]
    [InlineData(
        """{"comments":[{"id":"IC_5","author":"a","createdAt":"c","updatedAt":"u","body":"x"}],"threads":[]}"""
    )]
    [InlineData("""{"comments":[],"threads":[null]}""")]
    [InlineData("""{"comments":[],"threads":[{"comments":[]}]}""")]
    [InlineData("""{"comments":[],"threads":[{"path":"a"}]}""")]
    [InlineData("""{"comments":[],"threads":[{"path":"a","comments":[null]}]}""")]
    [InlineData("""{"comments":[],"threads":[{"path":"a","comments":[{"id":"5","author":"a","updatedAt":"u"}]}]}""")]
    [InlineData(
        """{"comments":[],"threads":[{"path":"a","comments":[{"id":"x","author":"a","updatedAt":"u","body":"b"}]}]}"""
    )]
    [InlineData("null")]
    public async Task CommentsInAnotherShapeAreAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .PullRequestCommentsAsync(
                    repository: "org/repo",
                    pullRequest: 7,
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's pr_comments result is not in the expected shape",
            actual: exception.Message
        );
    }

    [Fact]
    public async Task AnInlineCommentNeedsNoCreationTimeAsync()
    {
        PullRequestComments comments = await new GitHubReader(
            new FakeMcpToolCaller(
                result: """
                {"comments":[],"threads":[{"path":"a","comments":[{"id":"5","author":"a","updatedAt":"u","body":"b"}]}]}
                """,
                error: null
            )
        ).PullRequestCommentsAsync(repository: "org/repo", pullRequest: 7, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: [5L], actual: comments.ReviewComments.Select(comment => comment.Id));
        Assert.Empty(comments.Comments);
    }

    [Fact]
    public async Task ATopLevelCommentKeepsItsBodyWholeAsync()
    {
        PullRequestComments comments = await new GitHubReader(
            new FakeMcpToolCaller(result: "{\"comments\":[" + COMMENT + "],\"threads\":[]}", error: null)
        ).PullRequestCommentsAsync(repository: "org/repo", pullRequest: 7, cancellationToken: this.CancellationToken());

        Assert.Equal(
            expected: new PullRequestComment(
                Id: 5,
                Login: "owner",
                Body: "x",
                CreatedAt: "2026-11-01T10:00:00Z",
                UpdatedAt: "2026-11-02T10:00:00Z"
            ),
            actual: Assert.Single(comments.Comments)
        );
    }

    [Fact]
    public async Task ClosingIssuesAreAskedOfPrViewForTheClosingIssuesFieldAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """
            {"pr":"org/repo#7","closingIssues":[
              {"repository":"org/repo","number":12},{"repository":"org/other","number":3}
            ]}
            """,
            error: null
        );

        IReadOnlyList<int> issues = await new GitHubReader(tools).PullRequestClosingIssuesAsync(
            repository: "org/repo",
            pullRequest: 7,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: [12, 3], actual: issues);
        Assert.Equal(expected: "pr_view", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = "org/repo",
                ["pr"] = "7",
                ["fields"] = "[\"closing-issues\"]",
            },
            actual: tools.Arguments
        );
    }

    [Theory]
    [InlineData("""{"pr":"org/repo#7"}""")]
    [InlineData("""{"closingIssues":[null]}""")]
    [InlineData("""{"closingIssues":[{"repository":"org/repo","number":0}]}""")]
    [InlineData("""{"closingIssues":[{"repository":"org/repo"}]}""")]
    public async Task ClosingIssuesInAnotherShapeAreAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .PullRequestClosingIssuesAsync(
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
    public async Task ClosingIssueLabelsAreAskedOfClosingIssueLabelsAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """{"labels":["Bug","enhancement"],"complete":false,"failedReferences":["org/repo#6"]}""",
            error: null
        );

        IReadOnlyList<string> labels = await new GitHubReader(tools).ClosingIssueLabelsAsync(
            repository: "org/repo",
            pullRequest: 7,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: ["Bug", "enhancement"], actual: labels);
        Assert.Equal(expected: "closing_issue_labels", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal) { ["repo"] = "org/repo", ["pr"] = "7" },
            actual: tools.Arguments
        );
    }

    [Theory]
    [InlineData("""{"complete":true}""")]
    [InlineData("""{"labels":[null]}""")]
    [InlineData("""{"labels":[""]}""")]
    [InlineData("null")]
    public async Task ClosingIssueLabelsInAnotherShapeAreAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            new GitHubReader(new FakeMcpToolCaller(result: result, error: null))
                .ClosingIssueLabelsAsync(
                    repository: "org/repo",
                    pullRequest: 7,
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the cfwf MCP server's closing_issue_labels result is not in the expected shape",
            actual: exception.Message
        );
    }
}
