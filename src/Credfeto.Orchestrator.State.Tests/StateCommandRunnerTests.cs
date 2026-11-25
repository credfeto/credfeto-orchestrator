using System;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

public sealed class StateCommandRunnerTests : TestBase
{
    [Fact]
    public async Task AUsageErrorPrintsTheUsageAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using MemoryStream output = new();

        int status = await Runner()
            .RunAsync(
                args: ["state", "rate-limit"],
                output: output,
                error: error,
                cancellationToken: this.CancellationToken()
            );

        Assert.Equal(expected: StateCommandRunner.Usage, actual: status);
        Assert.Contains(
            expectedSubstring: "Usage: credfeto-orchestrator state",
            actualString: error.ToString(),
            comparisonType: StringComparison.Ordinal
        );
        Assert.Equal(expected: 0, actual: output.Length);
    }

    [Fact]
    public async Task AnArgumentThatWasNotUtf8IsRefusedAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using MemoryStream output = new();

        int status = await Runner()
            .RunAsync(
                args: ["state", "rate-limit", "--state-dir", "/nowhere", "--owner", "bad\uFFFD"],
                output: output,
                error: error,
                cancellationToken: this.CancellationToken()
            );

        Assert.Equal(expected: StateCommandRunner.Refused, actual: status);
        Assert.Equal(
            expected: "credfeto-orchestrator: state: an argument is not UTF-8" + Environment.NewLine,
            actual: error.ToString()
        );
    }

    [Fact]
    public async Task AMissingFileIsAnsweredAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using MemoryStream output = new();

        int status = await Runner()
            .RunAsync(
                args: ["state", "invocations", "--session-dir", "/nowhere", "--type", "Issue", "--id", "7"],
                output: output,
                error: error,
                cancellationToken: this.CancellationToken()
            );

        Assert.Equal(expected: StateQueries.Answered, actual: status);
        Assert.Equal(expected: "0 0"u8.ToArray(), actual: output.ToArray());
        Assert.Equal(expected: string.Empty, actual: error.ToString());
    }

    [Fact]
    public async Task AnAnswerThatCannotBeWrittenFailsAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using FailingStream output = new();

        int status = await Runner()
            .RunAsync(
                args: ["state", "session-denials-summary", "--file", "/nowhere/session-denials.2026-11-24"],
                output: output,
                error: error,
                cancellationToken: this.CancellationToken()
            );

        Assert.Equal(expected: StateCommandRunner.Failed, actual: status);
        Assert.Contains(
            expectedSubstring: "broken pipe",
            actualString: error.ToString(),
            comparisonType: StringComparison.Ordinal
        );
    }

    private static StateCommandRunner Runner()
    {
        return new(new StateQueries(new FakeTimeProvider()));
    }
}
