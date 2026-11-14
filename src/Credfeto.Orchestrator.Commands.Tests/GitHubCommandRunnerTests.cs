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
