using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Install.Tests;

public sealed class SelfCommandRunnerTests : TestBase
{
    private const string VERSION = "1.2.3.4-main+0123abc";

    [Fact]
    public async Task VersionPrintsTheVersionAsync()
    {
        FakeSelfTestCheck check = new("never");

        (int status, string output, string error) = await this.RunAsync(checks: [check], args: "--version");

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(expected: VERSION + Environment.NewLine, actual: output);
        Assert.Equal(expected: string.Empty, actual: error);
        Assert.Equal(expected: 0, actual: check.Runs);
    }

    [Fact]
    public async Task SelfTestRunsEveryCheckInOrderAsync()
    {
        FakeSelfTestCheck first = new("first");
        FakeSelfTestCheck second = new("second");

        (int status, string output, string error) = await this.RunAsync(checks: [first, second], args: "--self-test");

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(
            expected: Lines("self-test: first ok", "self-test: second ok", "self-test: passed (2 checks)"),
            actual: output
        );
        Assert.Equal(expected: string.Empty, actual: error);
        Assert.Equal(expected: 1, actual: first.Runs);
        Assert.Equal(expected: 1, actual: second.Runs);
    }

    [Fact]
    public async Task AFailedCheckIsNamedAndStopsTheSelfTestAsync()
    {
        FakeSelfTestCheck first = new("first");
        FakeSelfTestCheck failing = new(name: "broken", failure: new SelfTestFailedException("expected a, got b"));
        FakeSelfTestCheck last = new("last");

        (int status, string output, string error) = await this.RunAsync(
            checks: [first, failing, last],
            args: "--self-test"
        );

        Assert.Equal(expected: SelfCommandRunner.Failed, actual: status);
        Assert.Equal(expected: Lines("self-test: first ok"), actual: output);
        Assert.Equal(
            expected: Lines("credfeto-orchestrator: self-test: broken failed: expected a, got b"),
            actual: error
        );
        Assert.Equal(expected: 0, actual: last.Runs);
    }

    [Fact]
    public async Task CapabilitiesPrintsTheHeaderThenEveryCommandAsync()
    {
        FakeSelfTestCheck check = new("never");

        (int status, string output, string error) = await this.RunAsync(checks: [check], args: "--capabilities");

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(expected: Lines([ToolCapabilities.Header, .. ToolCapabilities.Lines]), actual: output);
        Assert.Equal(expected: string.Empty, actual: error);
        Assert.Equal(expected: 0, actual: check.Runs);
    }

    [Fact]
    public async Task ACancelledSelfTestExitsCancelledAsync()
    {
        FakeSelfTestCheck cancelled = new(name: "slow", failure: new OperationCanceledException());

        (int status, string output, _) = await this.RunAsync(checks: [cancelled], args: "--self-test");

        Assert.Equal(expected: SelfCommandRunner.Cancelled, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
    }

    [Theory]
    [InlineData("--version|now", "credfeto-orchestrator: --version takes no arguments")]
    [InlineData("--self-test|--version", "credfeto-orchestrator: --self-test takes no arguments")]
    [InlineData("--capabilities|all", "credfeto-orchestrator: --capabilities takes no arguments")]
    [InlineData("version", "credfeto-orchestrator: expected: --version, --self-test or --capabilities")]
    public async Task AUsageErrorPrintsTheUsageAsync(string args, string expected)
    {
        FakeSelfTestCheck check = new("never");

        (int status, string output, string error) = await this.RunAsync(checks: [check], args: args);

        Assert.Equal(expected: SelfCommandRunner.Usage, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.StartsWith(expectedStartString: expected, actualString: error, comparisonType: StringComparison.Ordinal);
        Assert.Contains(
            expectedSubstring: "Usage: credfeto-orchestrator --version",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Equal(expected: 0, actual: check.Runs);
    }

    [Fact]
    public async Task TheBuiltInChecksPassAsync()
    {
        await using StringWriter output = new();
        await using StringWriter error = new();

        int status = await SelfCommandRunner
            .CreateDefault(VERSION)
            .RunAsync(args: ["--self-test"], output: output, error: error, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(
            expected: Lines(
                "self-test: config ok",
                "self-test: json ok",
                "self-test: fingerprint ok",
                "self-test: prompt templates ok",
                "self-test: passed (4 checks)"
            ),
            actual: output.ToString()
        );
        Assert.Equal(expected: string.Empty, actual: error.ToString());
    }

    private static string Lines(params IReadOnlyList<string> lines)
    {
        return string.Concat(lines.Select(line => line + Environment.NewLine));
    }

    private async Task<(int Status, string Output, string Error)> RunAsync(
        IReadOnlyList<ISelfTestCheck> checks,
        string args
    )
    {
        await using StringWriter output = new();
        await using StringWriter error = new();

        int status = await new SelfCommandRunner(version: VERSION, checks: checks).RunAsync(
            args: args.Split('|'),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (status, output.ToString(), error.ToString());
    }
}
