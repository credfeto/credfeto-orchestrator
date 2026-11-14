using System.IO;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class GitHubParityTests : TestBase
{
    public static Task<TheoryData<int, string>> OpenPullRequestCasesAsync()
    {
        return GitHubParityFixture.CaseNamesAsync(GitHubParityFixture.OpenPullRequests.Collection);
    }

    public static Task<TheoryData<int, string>> BranchCasesAsync()
    {
        return GitHubParityFixture.CaseNamesAsync(GitHubParityFixture.BranchRequiresStatusChecks.Collection);
    }

    [Theory]
    [MemberData(nameof(OpenPullRequestCasesAsync))]
    public Task OpenPullRequestNumbersMatchTheShellVersionAsync(int index, string name)
    {
        return this.CheckAsync(read: GitHubParityFixture.OpenPullRequests, index: index, name: name);
    }

    [Theory]
    [MemberData(nameof(OpenPullRequestCasesAsync))]
    public Task OpenPullRequestCountMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckAsync(read: GitHubParityFixture.OpenPullRequestCount, index: index, name: name);
    }

    [Theory]
    [MemberData(nameof(BranchCasesAsync))]
    public Task BranchRequiresStatusChecksMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckAsync(read: GitHubParityFixture.BranchRequiresStatusChecks, index: index, name: name);
    }

    private async Task CheckAsync(GitHubParityRead read, int index, string name)
    {
        GitHubParityCase parity = await GitHubParityFixture.CaseAsync(
            read: read,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        FakeMcpToolCaller tools = new(result: parity.McpResult, error: parity.McpError);
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FakeFileContentReader(),
            github: new GitHubReader(tools)
        );

        string? actual = await this.RunAsync(
            runner: runner,
            "github",
            read.Read,
            "--repo",
            parity.Repository,
            "--" + read.NameField,
            parity.Name
        );

        Assert.Equal(
            expected: Describe(name: name, printed: parity.Expected),
            actual: Describe(name: name, printed: actual)
        );
        Assert.Equal(expected: read.Tool, actual: tools.Tool);
        Assert.Equal(expected: parity.Repository, actual: tools.Arguments?["repo"]);
        Assert.Equal(expected: parity.Name, actual: tools.Arguments?[read.NameArgument]);
    }

    // What the shell's command substitution keeps: the output without its trailing newlines, or null on a failure
    private async Task<string?> RunAsync(CommandRunner runner, params string[] args)
    {
        using MemoryStream stdin = new();
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await runner.RunAsync(
            args: args,
            input: stdin,
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return exitCode == ExitCodes.Success ? output.ToString().TrimEnd('\n') : null;
    }

    private static string Describe(string name, string? printed)
    {
        return name + ": " + (printed ?? "fails");
    }
}
