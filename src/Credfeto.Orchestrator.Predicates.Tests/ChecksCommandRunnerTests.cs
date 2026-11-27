using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Predicates.Tests;

public sealed class ChecksCommandRunnerTests : TestBase
{
    private const string CHECKS = "checks";

    [Fact]
    public async Task PrintsThePhaseAndExitsZeroAsync()
    {
        (int exitCode, string output, string error) = await this.RunAsync(
            input: "{\"reviewDecision\":\"CHANGES_REQUESTED\"}",
            CHECKS,
            "next-phase",
            "--board-status",
            "AI Review",
            "--required-checks-unknown",
            "false"
        );

        Assert.Equal(expected: 0, actual: exitCode);
        Assert.Equal(expected: "PHASE C (address the requested changes)", actual: output);
        Assert.Empty(error);
    }

    [Fact]
    public async Task ExitsOneWhenTheBoardStatusNamesNoPhaseAsync()
    {
        (int exitCode, string output, _) = await this.RunAsync(
            input: "{}",
            CHECKS,
            "next-phase",
            "--board-status",
            "Complete",
            "--required-checks-unknown",
            "false"
        );

        Assert.Equal(expected: ChecksCommandRunner.No, actual: exitCode);
        Assert.Empty(output);
    }

    [Fact]
    public async Task RefusesAnArgumentThatIsNotUtf8Async()
    {
        (int exitCode, string output, string error) = await this.RunAsync(
            input: string.Empty,
            CHECKS,
            "clean-review-comment",
            "--status",
            "AI � Coverage"
        );

        Assert.Equal(expected: ChecksCommandRunner.Refused, actual: exitCode);
        Assert.Empty(output);
        Assert.Contains(expectedSubstring: "not UTF-8", actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Fact]
    public async Task RefusesJsonStartingWithAByteOrderMarkAsync()
    {
        (int exitCode, _, string error) = await this.RunAsync(
            input: "﻿{\"labels\":[{\"name\":\"Blocked\"}]}",
            CHECKS,
            "has-blocked-label"
        );

        Assert.Equal(expected: ChecksCommandRunner.Refused, actual: exitCode);
        Assert.Contains(
            expectedSubstring: "byte order mark",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task RefusesCommentTimesTheLocaleCouldOrderAsync()
    {
        (int exitCode, _, _) = await this.RunAsync(
            input: string.Empty,
            CHECKS,
            "session-progress-reason",
            "--pre-board",
            "AI Review",
            "--post-board",
            "AI Review",
            "--pre-comment-ts",
            "B",
            "--post-comment-ts",
            "a",
            "--pre-head",
            "1",
            "--post-head",
            "1"
        );

        Assert.Equal(expected: ChecksCommandRunner.Refused, actual: exitCode);
    }

    [Fact]
    public async Task NeverReadsStdinForAQueryThatTakesNoneAsync()
    {
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await ChecksCommandRunner.RunAsync(
            args: [CHECKS, "clean-review-comment", "--status", "AI Coverage"],
            input: () => throw new InvalidOperationException("stdin was read"),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 0, actual: exitCode);
        Assert.StartsWith(
            expectedStartString: "Security review clean, advancing to coverage check",
            actualString: output.ToString(),
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task PrintsUsageForAnUnknownQueryAsync()
    {
        (int exitCode, string output, string error) = await this.RunAsync(input: string.Empty, CHECKS, "nope");

        Assert.Equal(expected: ChecksCommandRunner.Usage, actual: exitCode);
        Assert.Empty(output);
        Assert.Contains(expectedSubstring: "Usage:", actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Fact]
    public async Task FailsWhenStdinCannotBeReadAsync()
    {
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await ChecksCommandRunner.RunAsync(
            args: [CHECKS, "priority-for-labels"],
            input: () => throw new IOException("stdin is closed"),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: ChecksCommandRunner.Failed, actual: exitCode);
        Assert.Empty(output.ToString());
    }

    private async Task<(int ExitCode, string Output, string Error)> RunAsync(string input, params string[] args)
    {
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await ChecksCommandRunner.RunAsync(
            args: args,
            input: () => new MemoryStream(Encoding.UTF8.GetBytes(input)),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (exitCode, output.ToString(), error.ToString());
    }
}
