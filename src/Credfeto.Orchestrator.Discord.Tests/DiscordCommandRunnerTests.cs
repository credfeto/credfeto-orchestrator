using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class DiscordCommandRunnerTests : TestBase
{
    private const string HOST_HEALTH_PAYLOAD = """
        {
          "embeds": [
            {
              "title": "Host Health: gpg_agent_down",
              "color": 15158332,
              "description": "line one\nline \"two\""
            }
          ]
        }

        """;

    [Fact]
    public async Task APayloadPrintsAsJqPrintsItAsync()
    {
        (int status, string output, string error) = await this.RunAsync(
            "discord",
            "payload",
            "host-health",
            "--title",
            "Host Health: gpg_agent_down",
            "--message",
            "line one\nline \"two\""
        );

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(expected: HOST_HEALTH_PAYLOAD, actual: output);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public async Task AUsageErrorPrintsTheUsageAsync()
    {
        (int status, string output, string error) = await this.RunAsync("discord", "payload", "host-health");

        Assert.Equal(expected: DiscordCommandRunner.Usage, actual: status);
        Assert.Contains(
            expectedSubstring: "Usage: credfeto-orchestrator discord payload",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Equal(expected: string.Empty, actual: output);
    }

    [Fact]
    public async Task AnArgumentThatWasNotUtf8IsRefusedAsync()
    {
        (int status, string output, string error) = await this.RunAsync(
            "discord",
            "payload",
            "host-health",
            "--title",
            "t",
            "--message",
            "bad�"
        );

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.Equal(
            expected: "credfeto-orchestrator: discord: an argument is not UTF-8" + Environment.NewLine,
            actual: error
        );
    }

    [Theory]
    [InlineData("05")]
    [InlineData("-0")]
    [InlineData("1.5")]
    [InlineData(" 5")]
    [InlineData("5 ")]
    [InlineData("")]
    [InlineData("-")]
    [InlineData("+5")]
    [InlineData("1e2")]
    [InlineData("1234567890123456")]
    [InlineData("٥")]
    [InlineData("null")]
    public async Task ANumberJqMightPrintDifferentlyIsRefusedAsync(string number)
    {
        (int status, string output, string error) = await this.RunAsync(
            "discord",
            "payload",
            "self-update-stale",
            "--title",
            "t",
            "--head-sha",
            "abc",
            "--behind",
            number
        );

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.Equal(
            expected: "credfeto-orchestrator: discord: --behind is not a plain JSON integer" + Environment.NewLine,
            actual: error
        );
    }

    [Fact]
    public async Task APayloadThatCannotBeWrittenFailsAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using FailingWriter output = new();

        int status = await DiscordCommandRunner.RunAsync(
            args: ["discord", "payload", "no-work", "--title", "t", "--description", "d"],
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: DiscordCommandRunner.Failed, actual: status);
        Assert.Equal(
            expected: "credfeto-orchestrator: discord: broken pipe" + Environment.NewLine,
            actual: error.ToString()
        );
    }

    private async Task<(int Status, string Output, string Error)> RunAsync(params IReadOnlyList<string> args)
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using StringWriter output = new(CultureInfo.InvariantCulture);

        int status = await DiscordCommandRunner.RunAsync(
            args: args,
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (status, output.ToString(), error.ToString());
    }
}
