using System;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Git.Tests;

public sealed class GitStatusQueriesTests : TestBase
{
    private const string REPO = "/work/repo";
    private const string PORCELAIN = "status --porcelain --untracked-files=normal";
    private const string PORCELAIN_ALL = "status --porcelain --untracked-files=all";
    private const string STASH_HEAD = "rev-parse --verify -q refs/stash";
    private const string STASH_LIST = "stash list --format=%gd%x09%gs";
    private const string AUTO = "orchestrator-autostash";

    [Theory]
    [InlineData(0, " M a.txt\n?? \"caf\\303\\251\"\n\n")]
    [InlineData(128, "")]
    public async Task ThePorcelainStatusIsWhatGitPrintsWithItsStatusAsync(int status, string printed)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: PORCELAIN, exitCode: status, output: printed);

        GitResult result = await new GitQueries(git).PorcelainStatusAsync(
            repository: REPO,
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: status, expectedOutput: printed, result: result);
        Assert.Equal(expected: REPO, actual: git.Repository);
    }

    [Theory]
    [InlineData(0, "", "0\n")]
    [InlineData(0, " M a\n?? b\nR  c -> d\n", "3\n")]
    [InlineData(0, "?? no newline", "0\n")]
    [InlineData(0, "\n\n", "2\n")]
    [InlineData(128, "?? x\n", "1\n")]
    public async Task TheChangedFileCountIsTheNewlinesGitPrintsWhateverItsStatusAsync(
        int status,
        string printed,
        string expected
    )
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: PORCELAIN_ALL, exitCode: status, output: printed);

        GitResult result = await new GitQueries(git).ChangedFileCountAsync(
            repository: REPO,
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: 0, expectedOutput: expected, result: result);
    }

    [Theory]
    [InlineData(0, "abc\n")]
    [InlineData(1, "")]
    [InlineData(128, "")]
    public async Task TheStashHeadIsWhatRevParsePrintsWithItsStatusAsync(int status, string printed)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: STASH_HEAD, exitCode: status, output: printed);

        GitResult result = await new GitQueries(git).StashHeadAsync(
            repository: REPO,
            cancellationToken: this.CancellationToken()
        );

        AssertResult(expectedStatus: status, expectedOutput: printed, result: result);
    }

    [Theory]
    [InlineData("0", "stash@{2}\tOn main: orchestrator-autostash c\nstash@{0}\tOn x: orchestrator-autostash a\n")]
    [InlineData("1", "stash@{2}\tOn main: orchestrator-autostash c\n")]
    [InlineData("01", "stash@{2}\tOn main: orchestrator-autostash c\n")]
    [InlineData("2", "")]
    [InlineData("9223372036854775807", "")]
    public async Task TheAutostashesBeyondTheKeepAreListedHighestIndexFirstAsync(string keep, string expected)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: STASH_LIST,
            exitCode: 0,
            output: "stash@{0}\tOn x: orchestrator-autostash a\n"
                + "stash@{1}\tOn main: keep me\n"
                + "stash@{2}\tOn main: orchestrator-autostash c\n"
        );

        GitResult result = await this.AutostashesAsync(git: git, prefix: AUTO, keep: keep);

        AssertResult(expectedStatus: 0, expectedOutput: expected, result: result);
    }

    [Theory]
    [InlineData("stash@{0}\tOn main: orchestrator-autostash a\n", "stash@{0}\tOn main: orchestrator-autostash a\n")]
    [InlineData(
        "\t\tstash@{0}\t\tOn main: orchestrator-autostash a\t\t\n",
        "stash@{0}\tOn main: orchestrator-autostash a\n"
    )]
    [InlineData(
        "stash@{0}\tOn main: orchestrator-autostash a\tb\n",
        "stash@{0}\tOn main: orchestrator-autostash a\tb\n"
    )]
    [InlineData("stash@{0}\tOn main: orchestrator-autostash a", "")]
    [InlineData("stash@{0}\n\nx\tOn main: orchestrator-autostash a\n", "x\tOn main: orchestrator-autostash a\n")]
    [InlineData("stash@{0}\tOn : orchestrator-autostash a\n", "stash@{0}\tOn : orchestrator-autostash a\n")]
    [InlineData("stash@{0}\tOn café: orchestrator-autostash a\n", "stash@{0}\tOn café: orchestrator-autostash a\n")]
    [InlineData("stash@{0}\tOn main: orchestrator-autostash\n", "")]
    [InlineData("stash@{0}\tOn main: orchestrator-autostashx a\n", "")]
    [InlineData("stash@{0}\tOn main: note: orchestrator-autostash a\n", "")]
    [InlineData("stash@{0}\tOn main:orchestrator-autostash a\n", "")]
    [InlineData("stash@{0}\ton main: orchestrator-autostash a\n", "")]
    [InlineData("stash@{0}\tOn main: ORCHESTRATOR-AUTOSTASH a\n", "")]
    [InlineData("stash@{0}\tWIP on main: orchestrator-autostash a\n", "")]
    [InlineData("stash@{0}\t On main: orchestrator-autostash a\n", "")]
    public async Task EachLineIsReadAndMatchedAsBashDoesAsync(string printed, string expected)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: STASH_LIST, exitCode: 0, output: printed);

        GitResult result = await this.AutostashesAsync(git: git, prefix: AUTO, keep: "0");

        AssertResult(expectedStatus: 0, expectedOutput: expected, result: result);
    }

    [Theory]
    [InlineData("", "stash@{0}\tOn main:  x\n", "stash@{0}\tOn main:  x\n")]
    [InlineData("", "stash@{0}\tOn main: x\n", "")]
    [InlineData("keep_1-a", "stash@{0}\tOn main: keep_1-a x\n", "stash@{0}\tOn main: keep_1-a x\n")]
    public async Task AnyPlainPrefixIsMatchedLiterallyAsync(string prefix, string printed, string expected)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: STASH_LIST, exitCode: 0, output: printed);

        GitResult result = await this.AutostashesAsync(git: git, prefix: prefix, keep: "0");

        AssertResult(expectedStatus: 0, expectedOutput: expected, result: result);
    }

    [Fact]
    public async Task AStashListGitCannotReadIsEmptyWithStatusZeroAsync()
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: STASH_LIST, exitCode: 128, output: "");

        GitResult result = await this.AutostashesAsync(git: git, prefix: AUTO, keep: "0");

        AssertResult(expectedStatus: 0, expectedOutput: "", result: result);
    }

    [Theory]
    [InlineData("a.b", "0")]
    [InlineData("a b", "0")]
    [InlineData("é", "0")]
    [InlineData("[a]", "0")]
    [InlineData(AUTO, "")]
    [InlineData(AUTO, "x")]
    [InlineData(AUTO, "-1")]
    [InlineData(AUTO, "+1")]
    [InlineData(AUTO, " 1")]
    [InlineData(AUTO, "١")]
    [InlineData(AUTO, "9223372036854775808")]
    public async Task APrefixOrKeepBashReadsDifferentlyIsRefusedBeforeGitRunsAsync(string prefix, string keep)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(command: STASH_LIST, exitCode: 0, output: "");

        await Assert.ThrowsAsync<GitRefusedException>(() =>
            this.AutostashesAsync(git: git, prefix: prefix, keep: keep)
        );
        Assert.Empty(git.Ran);
    }

    [Theory]
    [InlineData("7309 4F6E 20FF 3A0A")]
    [InlineData("7309 4F6E 20C3 3A0A")]
    [InlineData("7309 4F6E 20ED A080 3A0A")]
    [InlineData("7309 4F6E 003A 0A")]
    public Task AStashListThatIsNotUtf8OrHoldsANulIsRefusedAsync(string printed)
    {
        FakeGitRunner git = new FakeGitRunner().Returns(
            command: STASH_LIST,
            exitCode: 0,
            output: Convert.FromHexString(
                printed.Replace(oldValue: " ", newValue: "", comparisonType: StringComparison.Ordinal)
            )
        );

        return Assert.ThrowsAsync<GitRefusedException>(() => this.AutostashesAsync(git: git, prefix: AUTO, keep: "0"));
    }

    private Task<GitResult> AutostashesAsync(FakeGitRunner git, string prefix, string keep)
    {
        return new GitQueries(git)
            .AutostashesBeyondKeepAsync(
                repository: REPO,
                prefix: prefix,
                keep: keep,
                cancellationToken: this.CancellationToken()
            )
            .AsTask();
    }

    private static void AssertResult(int expectedStatus, string expectedOutput, GitResult result)
    {
        Assert.Equal(expected: expectedStatus, actual: result.ExitCode);
        Assert.Equal(expected: expectedOutput, actual: Encoding.UTF8.GetString(result.Output.Span));
    }
}
