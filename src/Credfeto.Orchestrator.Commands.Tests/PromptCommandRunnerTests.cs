using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class PromptCommandRunnerTests : TestBase
{
    private const string LAUNCH = "repo-full=o/r\0item=1\0repo-path=/w\0";

    [Theory]
    [InlineData("unknown prompt kind 'poem'", "poem")]
    [InlineData("expected: prompt <kind>", "")]
    [InlineData("takes no options", "issue-launch|--max|1")]
    [InlineData("needs --max <n>", "check-length")]
    [InlineData("--max must be a non-negative integer, not '-1'", "check-length|--max|-1")]
    [InlineData("--max must be a non-negative integer, not 'x'", "check-length|--max|x")]
    public async Task AUsageErrorExitsTwoAsync(string problem, string rest)
    {
        string[] args = rest.Length == 0 ? ["prompt"] : ["prompt", .. rest.Split('|')];

        Result result = await this.RunAsync(stdin: string.Empty, args: args);

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.Contains(
            expectedSubstring: problem,
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Contains(
            expectedSubstring: "Usage: credfeto-orchestrator prompt",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData("repo-full=o/r\0item=1\0", "record 'repo-path' is missing")]
    [InlineData("repo-full=o/r\0item=1\0item=2\0repo-path=/w\0", "record 'item' is given more than once")]
    [InlineData("repo-full=o/r\0item=1\0repo-path=/w\0colour=red\0", "unexpected record 'colour'")]
    [InlineData("repo-full=o/r\0item\0repo-path=/w\0", "unexpected record 'item'")]
    [InlineData("repo-full=o/r\0item=1\0repo-path=/w", "the last record is not ended by a NUL byte")]
    [InlineData("", "record 'repo-full' is missing")]
    public async Task RecordsThatAreNotExactlyTheKindsNamesAreAUsageErrorAsync(string stdin, string problem)
    {
        Result result = await this.RunAsync(stdin: stdin, args: ["prompt", "issue-launch"]);

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.Contains(
            expectedSubstring: problem,
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task ARecordValueKeepsEveryEqualsSignAfterTheFirstAsync()
    {
        Result result = await this.RunAsync(
            stdin: "repo-full=o/r\0item=a=b\0repo-path=/w\0",
            args: ["prompt", "issue-launch"]
        );

        Assert.Equal(expected: ExitCodes.Success, actual: result.ExitCode);
        Assert.Equal(
            expected: "Work on issue #a=b in o/r.\nThe repository is checked out at /w.\n",
            actual: result.Output
        );
    }

    [Fact]
    public async Task InputThatIsNotUtf8IsRefusedSoTheShellBuildsItAsync()
    {
        byte[] stdin =
        [
            .. Encoding.UTF8.GetBytes("repo-full=o/r\0item="),
            0xff,
            .. Encoding.UTF8.GetBytes("\0repo-path=/w\0"),
        ];

        Result result = await this.RunAsync(stdin: stdin, args: ["prompt", "issue-launch"]);

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.Contains(
            expectedSubstring: "the input is not valid UTF-8",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task ABoardRecordThatIsNotTrueOrFalseIsRefusedAsync()
    {
        const string stdin =
            "repo-full=o/r\0board=yes\0item=1\0ai-instructions=/ai\0repo-path=/w\0plan-approved=false\0trusted-logins=\0"
            + "dirty-branch=\0stale-branch=\0background-stall=false\0precheck-section=\0";

        Result result = await this.RunAsync(stdin: stdin, args: ["prompt", "issue-claude-md"]);

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Contains(
            expectedSubstring: "Record 'board' must be true or false, not 'yes'",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task CheckLengthCountsBytesWithoutAUtf8LocaleAsync()
    {
        Result result = await this.RunAsync(stdin: "é", args: ["prompt", "check-length", "--max", "1"]);

        Assert.Equal(expected: PromptCommandRunner.TooLong, actual: result.ExitCode);
        Assert.Equal(expected: "2\n", actual: result.Output);
    }

    [Fact]
    public async Task ACancelledRunExitsWithTheCancelledCodeAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();
        PromptCommandRunner runner = new(_ => null);
        using MemoryStream input = new(Encoding.UTF8.GetBytes(LAUNCH));
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await runner.RunAsync(
            args: ["prompt", "issue-launch"],
            input: input,
            output: output,
            error: error,
            cancellationToken: cancelled.Token
        );

        Assert.Equal(expected: ExitCodes.Cancelled, actual: exitCode);
    }

    [Fact]
    public static void OnlyThePromptVerbIsAPromptCommand()
    {
        Assert.True(condition: PromptCommandParser.IsVerb(["prompt", "issue-launch"]), userMessage: "prompt");
        Assert.False(condition: PromptCommandParser.IsVerb(["github", "open-prs"]), userMessage: "github");
        Assert.False(condition: PromptCommandParser.IsVerb([]), userMessage: "no arguments");
    }

    private Task<Result> RunAsync(string stdin, string[] args)
    {
        return this.RunAsync(stdin: Encoding.UTF8.GetBytes(stdin), args: args);
    }

    private async Task<Result> RunAsync(byte[] stdin, string[] args)
    {
        PromptCommandRunner runner = new(_ => null);
        using MemoryStream input = new(stdin);
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await runner.RunAsync(
            args: args,
            input: input,
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return new(ExitCode: exitCode, Output: output.ToString(), Error: error.ToString());
    }
}
