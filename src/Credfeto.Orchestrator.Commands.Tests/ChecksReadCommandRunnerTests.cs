using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

// What the checks reads print to stderr and how they end where the parity cases do not reach
public sealed class ChecksReadCommandRunnerTests : TestBase
{
    private const string REQUIRED = "{\"pr\":\"org/repo#7\",\"checks\":[{\"name\":\"build\",\"required\":true}]}";

    [Fact]
    public async Task AnOutdatedServerIsRefusedWithTheReasonOnStderrAsync()
    {
        Result result = await this.RunAsync(
            new(result: "{\"pr\":\"org/repo#7\",\"checks\":[{\"name\":\"build\"}]}", error: null),
            "checks",
            "required-check-names",
            "--repo",
            "org/repo",
            "--pr",
            "7"
        );

        Assert.Equal(expected: ChecksReadCommandRunner.Refused, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.Equal(
            expected: "credfeto-orchestrator: the cfwf MCP server's pr_view checks carry no required flag\n",
            actual: result.Error
        );
    }

    [Fact]
    public async Task AServerWithoutCommitCheckRunsIsRefusedWithoutAskingItAsync()
    {
        FakeMcpToolCaller tools = new(result: "{\"running\":1}", error: null, tools: ["pr_view"]);

        Result result = await this.RunAsync(
            tools,
            "checks",
            "has-running-check-runs",
            "--repo",
            "org/repo",
            "--sha",
            "abc"
        );

        Assert.Equal(expected: ChecksReadCommandRunner.Refused, actual: result.ExitCode);
        Assert.Equal(
            expected: "credfeto-orchestrator: the cfwf MCP server does not list commit_check_runs\n",
            actual: result.Error
        );
        Assert.Null(tools.Tool);
    }

    [Fact]
    public async Task AFailedLookupIsTwoWithTheServersMessageAsync()
    {
        Result result = await this.RunAsync(
            new(result: null, error: "the commit abc was not found in org/repo"),
            "checks",
            "has-running-check-runs",
            "--repo",
            "org/repo",
            "--sha",
            "abc"
        );

        Assert.Equal(expected: ChecksReadCommandRunner.LookupFailed, actual: result.ExitCode);
        Assert.Equal(
            expected: "credfeto-orchestrator: the commit abc was not found in org/repo\n",
            actual: result.Error
        );
    }

    [Fact]
    public async Task MoreChecksThanTheShellVersionReadsIsAFailureSaidOnStderrAsync()
    {
        string many =
            "{\"checks\":["
            + string.Join(separator: ',', values: Repeat(item: "{\"name\":\"a\",\"required\":true}", count: 101))
            + "]}";

        Result result = await this.RunAsync(
            new(result: many, error: null),
            "checks",
            "required-check-names",
            "--repo",
            "org/repo",
            "--pr",
            "7"
        );

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.Equal(
            expected: "credfeto-orchestrator: the pull request has 101 checks, more than the shell version reads\n",
            actual: result.Error
        );
    }

    [Fact]
    public async Task AUsageErrorExitsTwoWithTheUsageAsync()
    {
        Result result = await this.RunAsync(
            new(result: REQUIRED, error: null),
            "checks",
            "required-check-names",
            "--repo",
            "org/repo"
        );

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: checks required-check-names needs --repo <owner/repo> and --pr",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Contains(
            expectedSubstring: "credfeto-orchestrator checks has-running-check-runs --repo <owner/repo> --sha <commit>",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task ACancelledReadExitsAsCancelledAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();

        Result required = await RunCancellableAsync(
            tools: new(result: REQUIRED, error: null),
            args: ["checks", "required-check-names", "--repo", "org/repo", "--pr", "7"],
            cancellationToken: cancelled.Token
        );
        Result running = await RunCancellableAsync(
            tools: new(result: "{\"running\":0}", error: null),
            args: ["checks", "has-running-check-runs", "--repo", "org/repo", "--sha", "abc"],
            cancellationToken: cancelled.Token
        );

        Assert.Equal(expected: ExitCodes.Cancelled, actual: required.ExitCode);
        Assert.Equal(expected: ExitCodes.Cancelled, actual: running.ExitCode);
    }

    private static string[] Repeat(string item, int count)
    {
        string[] items = new string[count];
        Array.Fill(array: items, value: item);

        return items;
    }

    private Task<Result> RunAsync(FakeMcpToolCaller tools, params string[] args)
    {
        return RunCancellableAsync(tools: tools, args: args, cancellationToken: this.CancellationToken());
    }

    private static async Task<Result> RunCancellableAsync(
        FakeMcpToolCaller tools,
        string[] args,
        CancellationToken cancellationToken
    )
    {
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FakeFileContentReader(),
            github: new GitHubReader(tools),
            discovery: DiscoveryFakes.NotExpected(new GitHubReader(tools))
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
