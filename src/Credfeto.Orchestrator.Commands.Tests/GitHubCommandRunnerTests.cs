using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class GitHubCommandRunnerTests : TestBase
{
    private const string TWO_PULL_REQUESTS = """{"pullRequests":[{"number":4},{"number":19}]}""";

    [Fact]
    public async Task OpenPullRequestsArePrintedNewestFirstOneALineAsync()
    {
        Result result = await RunAsync(
            tools: new(result: TWO_PULL_REQUESTS, error: null),
            args: ["github", "open-prs", "--repo", "org/repo", "--head", "main"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: "19\n4\n", Error: string.Empty),
            actual: result
        );
    }

    [Fact]
    public async Task TheOpenPullRequestCountIsPrintedAsync()
    {
        Result result = await RunAsync(
            tools: new(result: TWO_PULL_REQUESTS, error: null),
            args: ["github", "open-pr-count", "--repo", "org/repo", "--head", "main"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: new(ExitCode: ExitCodes.Success, Output: "2\n", Error: string.Empty), actual: result);
    }

    [Theory]
    [InlineData("""{"checks":["build"]}""", "true\n")]
    [InlineData("""{"checks":[]}""", "false\n")]
    public async Task TheBranchReadPrintsTrueOrFalseAsync(string mcpResult, string expected)
    {
        Result result = await RunAsync(
            tools: new(result: mcpResult, error: null),
            args: ["github", "branch-requires-status-checks", "--repo", "org/repo", "--branch", "main"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: new(ExitCode: ExitCodes.Success, Output: expected, Error: string.Empty), actual: result);
    }

    [Fact]
    public async Task OwnPullRequestsArePrintedNewestFirstOneALineAsync()
    {
        Result result = await RunAsync(
            tools: new(
                result: """{"pullRequests":[{"number":4,"author":"app/prpixie","labels":[]},{"number":9,"author":"x","labels":[]},{"number":19,"author":"me","labels":[]}]}""",
                error: null
            ),
            args: ["github", "own-open-prs", "--repo", "org/repo", "--me", "me", "--creator", "app/prpixie"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: "19\n4\n", Error: string.Empty),
            actual: result
        );
    }

    [Fact]
    public async Task TheCurrentLoginIsPrintedOnItsOwnLineAsync()
    {
        Result result = await RunAsync(
            tools: new(
                result: """{"login":"bot-user","host":"mcp.example.test","version":"2022-11-28"}""",
                error: null
            ),
            args: ["github", "whoami"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: "bot-user\n", Error: string.Empty),
            actual: result
        );
    }

    [Fact]
    public async Task OpenPullRequestsWithClosingIssuesArePrintedAsOneLineOfJsonNewestFirstAsync()
    {
        Result result = await RunAsync(
            tools: new(
                result: """
                {"pullRequests":[
                  {"number":4,"head":"fix/2-a","author":"-","labels":[],"closingIssues":[]},
                  {"number":9,"head":"feat/5-b","author":"app/prpixie","labels":[],
                   "closingIssues":[{"repository":"org/repo","number":5},{"repository":"org/other","number":8}]}
                ]}
                """,
                error: null
            ),
            args: ["github", "open-prs-closing-issues", "--repo", "org/repo"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Success,
                Output: "[{\"number\":9,\"author\":{\"login\":\"app/prpixie\"},"
                    + "\"closingIssuesReferences\":[{\"number\":5},{\"number\":8}],\"headRefName\":\"feat/5-b\"},"
                    + "{\"number\":4,\"author\":{\"login\":\"\"},\"closingIssuesReferences\":[],"
                    + "\"headRefName\":\"fix/2-a\"}]\n",
                Error: string.Empty
            ),
            actual: result
        );
    }

    [Fact]
    public async Task CommitAuthorsArePrintedAsOneLineOfJsonAsync()
    {
        Result result = await RunAsync(
            tools: new(
                result: """
                {"pr":"org/repo#7","commits":[
                  {"oid":"abc","authors":[{"login":"bot-user","email":"bot@example.test","name":"Bot"}]},
                  {"oid":"def","authors":[{"login":"","email":"Jo <x>@example.test","name":"Jo"}]}
                ]}
                """,
                error: null
            ),
            args: ["github", "pr-commit-authors", "--repo", "org/repo", "--pr", "7"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Success,
                Output: "{\"commits\":[{\"authors\":[{\"login\":\"bot-user\",\"email\":\"bot@example.test\"}]},"
                    + "{\"authors\":[{\"login\":\"\",\"email\":\"Jo <x>@example.test\"}]}]}\n",
                Error: string.Empty
            ),
            actual: result
        );
    }

    [Fact]
    public async Task TheBehindByCountIsPrintedAsync()
    {
        Result result = await RunAsync(
            tools: new(result: """{"status":"diverged","aheadBy":2,"behindBy":14}""", error: null),
            args: ["github", "branch-behind-by", "--repo", "org/repo", "--base", "main", "--head", "fix/7-typo"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: new(ExitCode: ExitCodes.Success, Output: "14\n", Error: string.Empty), actual: result);
    }

    private const string COMMENTS = """
        {"pr":"org/repo#7","reviewDecision":"","reviews":[],"summary":{},
         "comments":[
           {"id":"12","author":"app/prpixie","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
            "body":"Summary \u001b \ud83e\udd16\n"},
           {"id":"9","author":"","createdAt":"2026-11-01T09:00:00Z","updatedAt":"2026-11-01T09:30:00Z","body":"Gone"}
         ],
         "threads":[
           {"path":"src/a.cs","comments":[
             {"id":"30","author":"owner","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-02T10:00:00Z","body":"x"},
             {"id":"41","author":"mannequin/old","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
              "body":"y"}
           ]},
           {"path":"lib/b","comments":[
             {"id":"35","author":"reviewer","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
              "body":"z"}
           ]}
         ]}
        """;

    [Fact]
    public async Task ReviewCommentsArePrintedAsOneLineOfRestShapedJsonInIdOrderAsync()
    {
        Result result = await RunAsync(
            tools: new(result: COMMENTS, error: null),
            args: ["github", "pr-review-comments", "--repo", "org/repo", "--pr", "7"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Success,
                Output: "[{\"user\":{\"login\":\"owner\"},\"path\":\"src/a.cs\",\"body\":\"x\","
                    + "\"updated_at\":\"2026-11-02T10:00:00Z\"},"
                    + "{\"user\":{\"login\":\"reviewer\"},\"path\":\"lib/b\",\"body\":\"z\","
                    + "\"updated_at\":\"2026-11-01T10:00:00Z\"},"
                    + "{\"user\":{\"login\":\"old\"},\"path\":\"src/a.cs\",\"body\":\"y\","
                    + "\"updated_at\":\"2026-11-01T10:00:00Z\"}]\n",
                Error: string.Empty
            ),
            actual: result
        );
    }

    [Fact]
    public async Task IssueCommentsArePrintedAsOneLineOfRestShapedJsonEscapedAsJqEscapesAsync()
    {
        Result result = await RunAsync(
            tools: new(result: COMMENTS, error: null),
            args: ["github", "pr-issue-comments", "--repo", "org/repo", "--pr", "7"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Success,
                Output: "[{\"user\":null,\"body\":\"Gone\",\"created_at\":\"2026-11-01T09:00:00Z\","
                    + "\"updated_at\":\"2026-11-01T09:30:00Z\"},"
                    + "{\"user\":{\"login\":\"prpixie[bot]\"},\"body\":\"Summary \\u001b \U0001F916\\n\","
                    + "\"created_at\":\"2026-11-01T10:00:00Z\",\"updated_at\":\"2026-11-01T10:00:00Z\"}]\n",
                Error: string.Empty
            ),
            actual: result
        );
    }

    [Fact]
    public async Task ClosingIssuesArePrintedOneALineInTheServersOrderAsync()
    {
        Result result = await RunAsync(
            tools: new(
                result: """
                {"pr":"org/repo#7","closingIssues":[{"repository":"org/repo","number":12},
                 {"repository":"org/other","number":3}]}
                """,
                error: null
            ),
            args: ["github", "pr-closing-issues", "--repo", "org/repo", "--pr", "7"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: "12\n3\n", Error: string.Empty),
            actual: result
        );
    }

    [Fact]
    public async Task ClosingIssueLabelsArePrintedOnceEachInCodePointOrderAsync()
    {
        Result result = await RunAsync(
            tools: new(
                result: """{"labels":["\uff01wide","\ud83d\ude00 smile","bug","Bug","bug"],"complete":true,"failedReferences":[]}""",
                error: null
            ),
            args: ["github", "closing-issue-labels", "--repo", "org/repo", "--pr", "7"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Success,
                Output: "Bug\nbug\n\uff01wide\n\U0001F600 smile\n",
                Error: string.Empty
            ),
            actual: result
        );
    }

    [Fact]
    public async Task NoClosingIssueLabelsPrintNothingAsync()
    {
        Result result = await RunAsync(
            tools: new(result: """{"labels":[],"complete":false,"failedReferences":["org/repo#5"]}""", error: null),
            args: ["github", "closing-issue-labels", "--repo", "org/repo", "--pr", "7"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: string.Empty, Error: string.Empty),
            actual: result
        );
    }

    [Fact]
    public async Task AFailedReadExitsOneWithItsMessageAsync()
    {
        Result result = await RunAsync(
            tools: new(result: null, error: "no GitHub token: set GH_ENTERPRISE_TOKEN or GH_TOKEN"),
            args: ["github", "open-prs", "--repo", "org/repo", "--head", "main"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Failure,
                Output: string.Empty,
                Error: "credfeto-orchestrator: no GitHub token: set GH_ENTERPRISE_TOKEN or GH_TOKEN"
                    + Environment.NewLine
            ),
            actual: result
        );
    }

    [Fact]
    public async Task AGitHubUsageErrorExitsTwoAsync()
    {
        Result result = await RunAsync(
            tools: new(result: null, error: "not expected"),
            args: ["github", "open-prs", "--repo", "org/repo"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: --head is required",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task ACancelledReadExitsWithTheSignalCodeAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();

        Result result = await RunAsync(
            tools: new(result: TWO_PULL_REQUESTS, error: null),
            args: ["github", "open-prs", "--repo", "org/repo", "--head", "main"],
            cancellationToken: cancelled.Token
        );

        Assert.Equal(expected: ExitCodes.Cancelled, actual: result.ExitCode);
    }

    private static async Task<Result> RunAsync(
        FakeMcpToolCaller tools,
        string[] args,
        CancellationToken cancellationToken
    )
    {
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FakeFileContentReader(),
            github: new GitHubReader(tools)
        );
        using MemoryStream stdin = new();
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await runner.RunAsync(
            args: args,
            input: stdin,
            output: output,
            error: error,
            cancellationToken: cancellationToken
        );

        return new(ExitCode: exitCode, Output: output.ToString(), Error: error.ToString());
    }
}
