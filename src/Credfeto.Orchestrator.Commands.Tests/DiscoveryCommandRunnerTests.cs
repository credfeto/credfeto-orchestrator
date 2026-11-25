using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class DiscoveryCommandRunnerTests : TestBase
{
    private const string FEED = "https://feed.example/priorities";
    private const string STATUS = "https://status.example/summary.json";

    [Fact]
    public async Task ThePrioritiesArePrintedWithANewlineAsync()
    {
        Result result = await RunAsync(
            urls: new("""{"priorities":[{"id":1,"status":"Open","isOnHold":false}]}"""),
            args: ["discovery", "priorities", "--url", FEED],
            mcp: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(ExitCode: 0, Output: "[{\"id\":1,\"status\":\"Open\",\"isOnHold\":false}]\n", Error: ""),
            actual: result
        );
    }

    [Fact]
    public async Task AFeedWithoutAJsonValuePrintsNothingAsync()
    {
        Result result = await RunAsync(
            urls: new(""),
            args: ["discovery", "priorities", "--url", FEED],
            mcp: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: new(ExitCode: 0, Output: "", Error: ""), actual: result);
    }

    [Fact]
    public async Task AnUnparseableFeedExitsThreeAndSaysWhyAsync()
    {
        Result result = await RunAsync(
            urls: new("[]"),
            args: ["discovery", "priorities", "--url", FEED, "--user", "me"],
            mcp: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: ExitCodes.Unparseable, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.StartsWith(
            expectedStartString: $"credfeto-orchestrator: the priorities feed at {FEED}?user=me is not the expected "
                + "JSON: ",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task AnUnreachableFeedExitsOneAndSaysHowOftenItWasTriedAsync()
    {
        Result result = await RunAsync(
            urls: new(null, null),
            args: ["discovery", "priorities", "--url", FEED, "--attempts", "2", "--delay-secs", "0"],
            mcp: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Failure,
                Output: "",
                Error: $"credfeto-orchestrator: the priorities feed at {FEED} could not be read after 2 attempt(s): "
                    + $"{FEED} could not be read: refused\n"
            ),
            actual: result
        );
    }

    [Fact]
    public async Task TrustedLoginsArePrintedWithoutANewlineAsync()
    {
        Result result = await RunAsync(
            urls: new(),
            args: ["discovery", "trusted-logins", "--repo", "org/repo", "--creator", "github-advanced-security[bot]"],
            mcp: new(failures: 0, result: """{"collaborators":[]}"""),
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(ExitCode: 0, Output: "[\n  \"copilot-pull-request-reviewer\"\n]", Error: ""),
            actual: result
        );
    }

    [Fact]
    public async Task CollaboratorsThatCannotBeReadExitOneAndSayWhyAsync()
    {
        Result result = await RunAsync(
            urls: new(),
            args: ["discovery", "trusted-logins", "--repo", "org/repo", "--attempts", "1"],
            mcp: new(failures: 1, result: """{"collaborators":[]}"""),
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Failure,
                Output: "",
                Error: "credfeto-orchestrator: the collaborators of org/repo could not be read after 1 attempt(s): "
                    + "the server is down\n"
            ),
            actual: result
        );
    }

    [Theory]
    [InlineData(
        """{"incidents":[{"name":"Down","impact":"major","created_at":"t","components":[{"name":"Issues"}]}]}""",
        0,
        "Down\tt\n"
    )]
    [InlineData(
        """{"incidents":[{"name":"Slow","impact":"minor","created_at":"t","components":[{"name":"Issues"}]}]}""",
        3,
        "Slow\tt\tIssues: unknown\n"
    )]
    [InlineData("""{"incidents":[]}""", 4, "")]
    public async Task TheGitHubIncidentIsPrintedWithItsExitCodeAsync(string status, int exitCode, string output)
    {
        Result result = await RunAsync(
            urls: new(status),
            args: ["discovery", "github-incident", "--url", STATUS],
            mcp: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: new(ExitCode: exitCode, Output: output, Error: ""), actual: result);
    }

    [Fact]
    public async Task AStatusThatCannotBeReadExitsOneAndSaysWhyAsync()
    {
        Result result = await RunAsync(
            urls: new(),
            args: ["discovery", "github-incident", "--url", STATUS],
            mcp: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Failure,
                Output: "",
                Error: $"credfeto-orchestrator: {STATUS} could not be read: refused\n"
            ),
            actual: result
        );
    }

    [Fact]
    public async Task AnInvalidDiscoveryCommandIsAUsageErrorAsync()
    {
        Result result = await RunAsync(
            urls: new(),
            args: ["discovery", "priorities"],
            mcp: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: --url is required\n",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task ACancelledDiscoveryCommandExitsWithTheSignalCodeAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();

        Result result = await RunAsync(
            urls: new(),
            args: ["discovery", "trusted-logins", "--repo", "org/repo"],
            mcp: new(failures: 0, result: """{"collaborators":[]}"""),
            cancellationToken: cancelled.Token
        );

        Assert.Equal(expected: ExitCodes.Cancelled, actual: result.ExitCode);
    }

    private static async Task<Result> RunAsync(
        FakeUrlReader urls,
        string[] args,
        ScriptedMcpToolCaller? mcp,
        CancellationToken cancellationToken
    )
    {
        GitHubReader github = new(mcp ?? new(failures: int.MaxValue, result: string.Empty));
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FakeFileContentReader(),
            github: github,
            discovery: DiscoveryFakes.Runner(urls: urls, delay: new(), github: github)
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
