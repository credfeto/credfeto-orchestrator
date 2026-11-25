using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Git;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class GitCommandRunnerTests : TestBase
{
    [Theory]
    [InlineData("git|head-sha|--repo|/r", "head-sha /r")]
    [InlineData("git|current-branch|--repo|/r", "current-branch /r")]
    [InlineData("git|uncommitted-changes|--repo|/r", "uncommitted-changes /r")]
    [InlineData("git|origin-branch-exists|--repo|/r|--branch|b", "origin-branch-exists /r b")]
    [InlineData("git|commits-behind|--repo|/r|--ref|HEAD|--upstream|u", "commits-behind /r HEAD u")]
    [InlineData("git|stale-issue-branch|--repo|/r|--issue|7", "stale-issue-branch /r 7")]
    public async Task EachQueryPrintsTheAnswerByteForByteAndExitsWithItsStatusAsync(string args, string asked)
    {
        FakeGitQueries queries = new(exitCode: 128, output: "café\n\n");

        Result result = await this.RunAsync(queries: queries, args: args);

        Assert.Equal(expected: new(ExitCode: 128, Output: "café\n\n", Error: string.Empty), actual: result);
        Assert.Equal(expected: [asked], actual: queries.Asked);
    }

    [Fact]
    public async Task ARefusedQueryExitsThreeSoBashAnswersItAsync()
    {
        FakeGitQueries queries = new(exitCode: 0, output: "x", failure: new GitRefusedException("by the locale"));

        Result result = await this.RunAsync(queries: queries, args: "git|stale-issue-branch|--repo|/r|--issue|7");

        Assert.Equal(
            expected: new(
                ExitCode: GitCommandRunner.Refused,
                Output: string.Empty,
                Error: "credfeto-orchestrator: git: by the locale\n"
            ),
            actual: result
        );
    }

    [Fact]
    public async Task AGitThatCannotRunExits125Async()
    {
        FakeGitQueries queries = new(exitCode: 0, output: "x", failure: new GitException("git could not be started"));

        Result result = await this.RunAsync(queries: queries, args: "git|head-sha|--repo|/r");

        Assert.Equal(expected: GitCommandRunner.Failed, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
    }

    [Fact]
    public async Task ACancelledQueryExitsAsCancelledAsync()
    {
        FakeGitQueries queries = new(exitCode: 0, output: "x", failure: new OperationCanceledException());

        Result result = await this.RunAsync(queries: queries, args: "git|head-sha|--repo|/r");

        Assert.Equal(expected: ExitCodes.Cancelled, actual: result.ExitCode);
    }

    [Fact]
    public async Task AUsageErrorExitsTwoWithTheUsageAndAsksNothingAsync()
    {
        FakeGitQueries queries = new(exitCode: 0, output: "x");

        Result result = await this.RunAsync(queries: queries, args: "git|head-sha");

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: git head-sha needs --repo\nUsage: credfeto-orchestrator git",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Empty(queries.Asked);
    }

    private async Task<Result> RunAsync(FakeGitQueries queries, string args)
    {
        await using MemoryStream output = new();
        await using StringWriter error = new();

        int exitCode = await new GitCommandRunner(queries).RunAsync(
            args: args.Split('|'),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return new(ExitCode: exitCode, Output: Encoding.UTF8.GetString(output.ToArray()), Error: error.ToString());
    }
}
