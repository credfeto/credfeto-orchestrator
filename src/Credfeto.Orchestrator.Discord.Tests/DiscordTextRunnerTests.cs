using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class DiscordTextRunnerTests : TestBase
{
    [Fact]
    public async Task TheItemStatusIsPrintedWithoutReadingStdinAsync()
    {
        (int status, string output, string error) = await this.RunAsync(
            input: null,
            "discord",
            "item-status",
            "--type",
            "Issue",
            "--id",
            "42",
            "--repo",
            "o/r",
            "--reason",
            "say \"hi\"\n"
        );

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(
            expected: "{\"type\":\"Issue\",\"id\":\"42\",\"repo\":\"o/r\",\"reason\":\"say \\\"hi\\\"\\n\"}\n",
            actual: output
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public async Task TheItemStatusLogIsReadFromStdinAsync()
    {
        (int status, string output, string error) = await this.RunAsync(
            input: "{\"type\":\"Issue\"}\n  {\"id\" : \"1\"}\n\n",
            "discord",
            "item-status-log"
        );

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(expected: "[{\"type\":\"Issue\"},{\"id\":\"1\"}]\n", actual: output);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public async Task TheBreakdownIsPrintedWithNoNewlineAsync()
    {
        (int status, string output, string error) = await this.RunAsync(
            input: "[{\"type\":\"Issue\",\"id\":\"1\",\"repo\":\"\",\"reason\":\"\"}]\n",
            "discord",
            "no-work-breakdown",
            "--default-repo",
            "d/r",
            "--length-unit",
            "characters"
        );

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(expected: "- [Issue #1 in ](https://github.com/d/r/issues/1): ", actual: output);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public async Task TheTextIsTruncatedAsync()
    {
        (int status, string output, string error) = await this.RunAsync(
            input: "abcdef\n",
            "discord",
            "truncate",
            "--max-length",
            "3"
        );

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(expected: "abc" + DisplayTruncation.Notice + "\n", actual: output);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("abc", "the input does not end with the newline a here-string adds")]
    [InlineData("", "the input does not end with the newline a here-string adds")]
    [InlineData("\uFEFFabc\n", "the input starts with a byte order mark")]
    [InlineData("a\0b\n", "the input holds a NUL")]
    public async Task InputTheToolCannotReadAsJqWouldIsRefusedAsync(string input, string message)
    {
        (int status, string output, string error) = await this.RunAsync(
            input: input,
            "discord",
            "truncate",
            "--max-length",
            "3"
        );

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.Equal(expected: "credfeto-orchestrator: discord: " + message + Environment.NewLine, actual: error);
    }

    [Fact]
    public async Task InputThatIsNotUtf8IsRefusedAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using StringWriter output = new(CultureInfo.InvariantCulture);

        int status = await DiscordCommandRunner.RunAsync(
            args: ["discord", "truncate", "--max-length", "3"],
            input: () => new MemoryStream([(byte)'a', 0xff, (byte)'\n']),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(
            expected: "credfeto-orchestrator: discord: the input is not UTF-8" + Environment.NewLine,
            actual: error.ToString()
        );
    }

    [Theory]
    [InlineData("[1.5]\n", "the input holds a number jq might print differently")]
    [InlineData("[\"\\udc00\"]\n", "the input holds U+FFFD, which jq also puts in place of a lone surrogate")]
    [InlineData("{\"a\":\n", "the input is not JSON the tool reads exactly as jq does")]
    [InlineData("NaN\n", "the input is not JSON the tool reads exactly as jq does")]
    public async Task JsonJqMightReadDifferentlyIsRefusedAsync(string input, string message)
    {
        (int status, string output, string error) = await this.RunAsync(input: input, "discord", "item-status-log");

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.Equal(expected: "credfeto-orchestrator: discord: " + message + Environment.NewLine, actual: error);
    }

    [Fact]
    public async Task JsonNestedDeeperThanTheLimitIsRefusedAsync()
    {
        string deep = new string('[', 65) + new string(']', 65) + "\n";

        (int status, _, _) = await this.RunAsync(input: deep, "discord", "item-status-log");
        (int shallow, string output, _) = await this.RunAsync(
            input: new string('[', 64) + new string(']', 64) + "\n",
            "discord",
            "item-status-log"
        );

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: 0, actual: shallow);
        Assert.Equal(expected: "[" + new string('[', 64) + new string(']', 64) + "]\n", actual: output);
    }

    [Theory]
    [InlineData("--default-repo", "o/\uFFFD", "--length-unit", "characters", "an argument is not UTF-8")]
    [InlineData(
        "--default-repo",
        "o/r",
        "--length-unit",
        "unknown",
        "--length-unit unknown: the shell's locale counts neither characters nor bytes"
    )]
    public async Task ABreakdownTheToolCannotCountAsBashWouldIsRefusedAsync(
        string repoOption,
        string repo,
        string unitOption,
        string unit,
        string message
    )
    {
        (int status, string output, string error) = await this.RunAsync(
            input: "[]\n",
            "discord",
            "no-work-breakdown",
            repoOption,
            repo,
            unitOption,
            unit
        );

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.Equal(expected: "credfeto-orchestrator: discord: " + message + Environment.NewLine, actual: error);
    }

    [Fact]
    public async Task ATextCommandUsageErrorPrintsTheUsageAsync()
    {
        (int status, string output, string error) = await this.RunAsync(input: null, "discord", "truncate");

        Assert.Equal(expected: DiscordCommandRunner.Usage, actual: status);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: discord truncate needs --max-length <value>",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Contains(
            expectedSubstring: "credfeto-orchestrator discord truncate --max-length <n> < text",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Equal(expected: string.Empty, actual: output);
    }

    [Fact]
    public async Task TextThatCannotBeWrittenFailsAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using FailingWriter output = new();

        int status = await DiscordCommandRunner.RunAsync(
            args: ["discord", "truncate", "--max-length", "3"],
            input: () => new MemoryStream("abc\n"u8.ToArray()),
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

    // Runs the command with input as its stdin; a null input fails the test if the command opens stdin at all
    private async Task<(int Status, string Output, string Error)> RunAsync(
        string? input,
        params IReadOnlyList<string> args
    )
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using StringWriter output = new(CultureInfo.InvariantCulture);

        int status = await DiscordCommandRunner.RunAsync(
            args: args,
            input: () =>
                input is null
                    ? throw new InvalidOperationException("stdin was opened")
                    : new MemoryStream(Encoding.UTF8.GetBytes(input)),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (status, output.ToString(), error.ToString());
    }
}
