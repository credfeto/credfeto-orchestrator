using System;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Git.Tests;

public sealed class GitQueriesTests : TestBase
{
    private const string REPO = "/work/repo";
    private const string BRANCHES = "branch -r --format=%(refname:short)";
    private const string AHEAD = "rev-list --count origin/main..";

    [Fact]
    public async Task TheHeadCommitIsWhatRevParsePrintsWithItsStatusAsync()
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: "rev-parse --verify -q HEAD",
            exitCode: 0,
            output: "abc\n"
        );

        GitResult result = await new GitQueries(git).HeadShaAsync(
            repository: REPO,
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: 0, expectedOutput: "abc\n", result: result);
        Assert.Equal(expected: REPO, actual: git.Repository);
    }

    [Fact]
    public async Task TheCurrentBranchIsWhatGitPrintsWithItsStatusAsync()
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: "branch --show-current", exitCode: 128, output: "");

        GitResult result = await new GitQueries(git).CurrentBranchAsync(
            repository: REPO,
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: 128, expectedOutput: "", result: result);
    }

    [Theory]
    [InlineData(1, 0, 0, "diff --quiet")]
    [InlineData(129, 0, 0, "diff --quiet")]
    [InlineData(0, 1, 0, "diff --quiet|diff --cached --quiet")]
    [InlineData(0, 128, 0, "diff --quiet|diff --cached --quiet")]
    [InlineData(0, 0, 1, "diff --quiet|diff --cached --quiet")]
    public async Task UncommittedChangesAreAnyDiffThatDoesNotSucceedAsync(
        int unstaged,
        int staged,
        int expected,
        string ran
    )
    {
        FakeGitRunner git = new FakeGitRunner()
            .Returns(command: "diff --quiet", exitCode: unstaged, output: "")
            .Returns(command: "diff --cached --quiet", exitCode: staged, output: "");

        GitResult result = await new GitQueries(git).UncommittedChangesAsync(
            repository: REPO,
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: expected, expectedOutput: "", result: result);
        Assert.Equal(expected: ran.Split('|'), actual: git.Ran);
    }

    [Fact]
    public async Task WhatTheDiffsPrintIsPrintedAsBashWouldAsync()
    {
        FakeGitRunner git = new FakeGitRunner()
            .Returns(command: "diff --quiet", exitCode: 0, output: "a")
            .Returns(command: "diff --cached --quiet", exitCode: 0, output: "b");

        GitResult result = await new GitQueries(git).UncommittedChangesAsync(
            repository: REPO,
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: 1, expectedOutput: "ab", result: result);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(128)]
    public async Task AnOriginBranchExistsAsRevParseSaysPrintingNothingAsync(int status)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: "rev-parse --verify -q refs/remotes/origin/feat/1-x",
            exitCode: status,
            output: "abc\n"
        );

        GitResult result = await new GitQueries(git).OriginBranchExistsAsync(
            repository: REPO,
            branch: "feat/1-x",
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: status, expectedOutput: "", result: result);
    }

    [Theory]
    [InlineData(0, "3\n", 0, "3")]
    [InlineData(0, "0\n\n", 0, "0")]
    [InlineData(0, "", 1, "")]
    [InlineData(0, "3 \n", 1, "")]
    [InlineData(0, "-3", 1, "")]
    [InlineData(128, "3\n", 1, "")]
    public async Task CommitsBehindIsTheCountWhenGitPrintsANumberAsync(
        int exitCode,
        string printed,
        int expectedStatus,
        string expectedOutput
    )
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: "rev-list --count HEAD..origin/main",
            exitCode: exitCode,
            output: printed
        );

        GitResult result = await new GitQueries(git).CommitsBehindAsync(
            repository: REPO,
            reference: "HEAD",
            upstream: "origin/main",
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: expectedStatus, expectedOutput: expectedOutput, result: result);
    }

    [Theory]
    [InlineData("²\n")]
    [InlineData("3\0")]
    public Task ACountBashMightReadDifferentlyIsRefusedAsync(string printed)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: "rev-list --count HEAD..origin/main",
            exitCode: 0,
            output: printed
        );

        return Assert.ThrowsAsync<GitRefusedException>(() =>
            new GitQueries(git)
                .CommitsBehindAsync(
                    repository: REPO,
                    reference: "HEAD",
                    upstream: "origin/main",
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );
    }

    [Fact]
    public async Task TheFirstMatchingBranchWithCommitsAheadIsTheStaleBranchAsync()
    {
        FakeGitRunner git = new FakeGitRunner()
            .Returns(
                command: BRANCHES,
                exitCode: 0,
                output: "origin\norigin/chore/12\n\norigin/feat/12-x\norigin/fix/12\n"
            )
            .Returns(command: AHEAD + "origin/chore/12", exitCode: 0, output: "0\n")
            .Returns(command: AHEAD + "origin/feat/12-x", exitCode: 0, output: "2\n");

        GitResult result = await this.StaleAsync(git: git, issue: "12");

        AssertResult(expectedStatus: 0, expectedOutput: "feat/12-x", result: result);
        Assert.Equal(expected: [BRANCHES, AHEAD + "origin/chore/12", AHEAD + "origin/feat/12-x"], actual: git.Ran);
    }

    [Fact]
    public async Task OnlyTheOriginPrefixIsStrippedAndOnlyOnceAsync()
    {
        FakeGitRunner git = new FakeGitRunner()
            .Returns(command: BRANCHES, exitCode: 0, output: "origin/origin/7-x\nupstream/7-y\n")
            .Returns(command: AHEAD + "upstream/7-y", exitCode: 0, output: "1\n");

        GitResult result = await this.StaleAsync(git: git, issue: "7");

        AssertResult(expectedStatus: 0, expectedOutput: "upstream/7-y", result: result);
    }

    [Fact]
    public async Task ABranchWhoseCountFailsIsSkippedAsync()
    {
        FakeGitRunner git = new FakeGitRunner()
            .Returns(command: BRANCHES, exitCode: 0, output: "origin/feat/5\n")
            .Returns(command: AHEAD + "origin/feat/5", exitCode: 128, output: "9\n");

        GitResult result = await this.StaleAsync(git: git, issue: "5");

        AssertResult(expectedStatus: 1, expectedOutput: "", result: result);
    }

    [Fact]
    public async Task TheListIsReadWhateverGitReturnsButALastLineWithNoNewlineIsNotAsync()
    {
        FakeGitRunner git = new FakeGitRunner()
            .Returns(command: BRANCHES, exitCode: 128, output: "origin/feat/5\norigin/feat/6")
            .Returns(command: AHEAD + "origin/feat/5", exitCode: 0, output: "1\n")
            .Returns(command: AHEAD + "origin/feat/6", exitCode: 0, output: "1\n");

        Assert.Equal(
            expected: "feat/5",
            actual: Encoding.UTF8.GetString((await this.StaleAsync(git: git, issue: "5")).Output.Span)
        );
        Assert.Equal(expected: 1, actual: (await this.StaleAsync(git: git, issue: "6")).ExitCode);
    }

    [Theory]
    [InlineData("")]
    [InlineData("12x")]
    [InlineData("-1")]
    [InlineData("٣")]
    public Task AnIssueThatIsNotANumberIsRefusedAsync(string issue)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: BRANCHES, exitCode: 0, output: "origin/feat/1\n");

        return Assert.ThrowsAsync<GitRefusedException>(() => this.StaleAsync(git: git, issue: issue).AsTask());
    }

    [Theory]
    [InlineData("origin/fé/12-x\n")]
    [InlineData("origin/feat/12é\n")]
    [InlineData("origin/feat/12-x\0\n")]
    public Task ABranchBashMatchesByTheLocaleIsRefusedAsync(string branches)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: BRANCHES, exitCode: 0, output: branches);

        return Assert.ThrowsAsync<GitRefusedException>(() => this.StaleAsync(git: git, issue: "12").AsTask());
    }

    [Fact]
    public Task AMatchingBranchNameThatIsNotUtf8IsRefusedAsync()
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: BRANCHES,
            exitCode: 0,
            output: [.. "origin/feat/12-"u8, 0xff, (byte)'\n']
        );

        return Assert.ThrowsAsync<GitRefusedException>(() => this.StaleAsync(git: git, issue: "12").AsTask());
    }

    [Fact]
    public Task ACommitCountThatIsNotANumberIsRefusedAsync()
    {
        FakeGitRunner git = new FakeGitRunner()
            .Returns(command: BRANCHES, exitCode: 0, output: "origin/feat/12\n")
            .Returns(command: AHEAD + "origin/feat/12", exitCode: 0, output: "x\n");

        return Assert.ThrowsAsync<GitRefusedException>(() => this.StaleAsync(git: git, issue: "12").AsTask());
    }

    [Fact]
    public async Task ANonAsciiBranchTheNumberRulesOutIsNotRefusedAsync()
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: BRANCHES,
            exitCode: 0,
            output: "origin/fé/88-x\norigin/feat/12²\n"
        );

        GitResult result = await this.StaleAsync(git: git, issue: "13");

        AssertResult(expectedStatus: 1, expectedOutput: "", result: result);
    }

    private ValueTask<GitResult> StaleAsync(FakeGitRunner git, string issue)
    {
        return new GitQueries(git).StaleIssueBranchAsync(
            repository: REPO,
            issue: issue,
            cancellationToken: this.CancellationToken()
        );
    }

    private static void AssertResult(int expectedStatus, string expectedOutput, GitResult result)
    {
        Assert.Equal(expected: expectedStatus, actual: result.ExitCode);
        Assert.Equal(expected: expectedOutput, actual: Encoding.UTF8.GetString(result.Output.Span));
    }
}
