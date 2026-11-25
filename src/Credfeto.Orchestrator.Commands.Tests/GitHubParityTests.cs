using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
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

    public static Task<TheoryData<int, string>> OwnPullRequestCasesAsync()
    {
        return GitHubParityFixture.CaseNamesAsync(GitHubParityFixture.OwnOpenPullRequests);
    }

    [Theory]
    [MemberData(nameof(OwnPullRequestCasesAsync))]
    public async Task OwnOpenPullRequestsMatchTheShellVersionAsync(int index, string name)
    {
        GitHubOwnParityCase parity = await GitHubParityFixture.OwnCaseAsync(
            index: index,
            cancellationToken: this.CancellationToken()
        );
        FakeMcpToolCaller tools = new(result: parity.McpResult, error: parity.McpError);

        string? actual = await this.RunAsync(
            runner: Runner(tools),
            "github",
            "own-open-prs",
            "--repo",
            parity.Repository,
            "--me",
            parity.Me,
            "--creator",
            parity.Creator,
            "--include-blocked",
            parity.IncludeBlocked
        );

        Assert.Equal(
            expected: Describe(name: name, printed: parity.Expected),
            actual: Describe(name: name, printed: actual)
        );
        Assert.Equal(expected: "pr_list", actual: tools.Tool);
        Assert.Equal(expected: parity.Repository, actual: tools.Arguments?["repo"]);
    }

    public static Task<TheoryData<int, string>> CurrentLoginCasesAsync()
    {
        return GitHubParityFixture.CaseNamesAsync("currentLogin");
    }

    [Theory]
    [MemberData(nameof(CurrentLoginCasesAsync))]
    public Task CurrentLoginMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckCaseAsync(
            collection: "currentLogin",
            index: index,
            name: name,
            tool: "auth_status",
            args: static _ => ["whoami"],
            arguments: static _ => [with(StringComparer.Ordinal)]
        );
    }

    public static Task<TheoryData<int, string>> ClosingIssuesCasesAsync()
    {
        return GitHubParityFixture.CaseNamesAsync("openPullRequestsWithClosingIssues");
    }

    [Theory]
    [MemberData(nameof(ClosingIssuesCasesAsync))]
    public Task OpenPullRequestsWithClosingIssuesMatchTheShellVersionAsync(int index, string name)
    {
        return this.CheckCaseAsync(
            collection: "openPullRequestsWithClosingIssues",
            index: index,
            name: name,
            tool: "pr_list",
            args: static item => ["open-prs-closing-issues", "--repo", Text(item: item, field: "repo")],
            arguments: static item =>
                new(StringComparer.Ordinal) { ["repo"] = Text(item: item, field: "repo"), ["closingIssues"] = "true" }
        );
    }

    public static Task<TheoryData<int, string>> CommitAuthorCasesAsync()
    {
        return GitHubParityFixture.CaseNamesAsync("pullRequestCommitAuthors");
    }

    [Theory]
    [MemberData(nameof(CommitAuthorCasesAsync))]
    public Task PullRequestCommitAuthorsMatchTheShellVersionAsync(int index, string name)
    {
        return this.CheckCaseAsync(
            collection: "pullRequestCommitAuthors",
            index: index,
            name: name,
            tool: "pr_view",
            args: static item =>
                ["pr-commit-authors", "--repo", Text(item: item, field: "repo"), "--pr", Text(item: item, field: "pr")],
            arguments: static item =>
                new(StringComparer.Ordinal)
                {
                    ["repo"] = Text(item: item, field: "repo"),
                    ["pr"] = Text(item: item, field: "pr"),
                    ["fields"] = "[\"commits\"]",
                }
        );
    }

    public static Task<TheoryData<int, string>> BehindByCasesAsync()
    {
        return GitHubParityFixture.CaseNamesAsync("branchBehindBy");
    }

    [Theory]
    [MemberData(nameof(BehindByCasesAsync))]
    public Task BranchBehindByMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckCaseAsync(
            collection: "branchBehindBy",
            index: index,
            name: name,
            tool: "branch_compare",
            args: static item =>
                [
                    "branch-behind-by",
                    "--repo",
                    Text(item: item, field: "repo"),
                    "--base",
                    Text(item: item, field: "base"),
                    "--head",
                    Text(item: item, field: "head"),
                ],
            arguments: static item =>
                new(StringComparer.Ordinal)
                {
                    ["repo"] = Text(item: item, field: "repo"),
                    ["base"] = Text(item: item, field: "base"),
                    ["head"] = Text(item: item, field: "head"),
                }
        );
    }

    // Runs "github <args>" against the case's MCP result or failure and checks what it prints against the case's
    // expected field (null: it must fail), and that it asked the tool with the given arguments
    private async Task CheckCaseAsync(
        string collection,
        int index,
        string name,
        string tool,
        Func<JsonElement, string[]> args,
        Func<JsonElement, Dictionary<string, string>> arguments
    )
    {
        JsonElement item = await GitHubParityFixture.ItemAsync(
            collection: collection,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        FakeMcpToolCaller tools = new(
            result: item.TryGetProperty(propertyName: "mcp", value: out JsonElement mcp) ? mcp.GetRawText() : null,
            error: item.TryGetProperty(propertyName: "mcpError", value: out JsonElement error)
                ? error.GetString()
                : null
        );

        string? actual = await this.RunAsync(Runner(tools), ["github", .. args(item)]);

        Assert.Equal(
            expected: Describe(name: name, printed: item.GetProperty("expected").GetString()),
            actual: Describe(name: name, printed: actual)
        );
        Assert.Equal(expected: tool, actual: tools.Tool);
        Assert.Equal(expected: arguments(item), actual: tools.Arguments);
    }

    private static string Text(JsonElement item, string field)
    {
        return item.GetProperty(field).GetString() ?? string.Empty;
    }

    private static CommandRunner Runner(FakeMcpToolCaller tools)
    {
        return new(
            fingerprints: new FingerprintCalculator(),
            files: new FakeFileContentReader(),
            github: new GitHubReader(tools),
            discovery: DiscoveryFakes.NotExpected(new GitHubReader(tools))
        );
    }

    private async Task CheckAsync(GitHubParityRead read, int index, string name)
    {
        GitHubParityCase parity = await GitHubParityFixture.CaseAsync(
            read: read,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        FakeMcpToolCaller tools = new(result: parity.McpResult, error: parity.McpError);
        CommandRunner runner = Runner(tools);

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
