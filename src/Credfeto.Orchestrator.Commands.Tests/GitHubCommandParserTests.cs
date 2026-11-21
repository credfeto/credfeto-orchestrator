using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class GitHubCommandParserTests : TestBase
{
    [Theory]
    [InlineData("open-prs", GitHubRead.OPEN_PULL_REQUESTS)]
    [InlineData("open-pr-count", GitHubRead.OPEN_PULL_REQUEST_COUNT)]
    public static void APullRequestReadTakesTheRepositoryAndHead(string read, GitHubRead expected)
    {
        GitHubCommand? command = GitHubCommandParser.Parse(
            args: ["github", read, "--head", "fix/7-typo", "--repo", "org/repo"],
            error: out string error
        );

        Assert.Equal(
            expected: new GitHubCommand(Read: expected, Repository: "org/repo", Name: "fix/7-typo"),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public static void TheBranchReadTakesTheRepositoryAndBranch()
    {
        GitHubCommand? command = GitHubCommandParser.Parse(
            args: ["github", "branch-requires-status-checks", "--repo", "org/repo", "--branch", "release/1.0"],
            error: out string error
        );

        Assert.Equal(
            expected: new GitHubCommand(
                Read: GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS,
                Repository: "org/repo",
                Name: "release/1.0"
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("true", true)]
    [InlineData("false", false)]
    public static void TheOwnPullRequestReadTakesTheRepositoryLoginsAndBlockedChoice(string value, bool expected)
    {
        GitHubCommand? command = GitHubCommandParser.Parse(
            args:
            [
                "github",
                "own-open-prs",
                "--creator",
                "app/prpixie",
                "--repo",
                "org/repo",
                "--include-blocked",
                value,
                "--me",
                "bot-user",
            ],
            error: out string error
        );

        Assert.Equal(
            expected: new GitHubCommand(
                Read: GitHubRead.OWN_OPEN_PULL_REQUESTS,
                Repository: "org/repo",
                Name: "bot-user",
                Creator: "app/prpixie",
                IncludeBlocked: expected
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public static void BlockedPullRequestsAreLeftOutWhenNotSaid()
    {
        GitHubCommand? command = GitHubCommandParser.Parse(
            args: ["github", "own-open-prs", "--repo", "org/repo", "--me", "bot-user", "--creator", "app/prpixie"],
            error: out _
        );

        Assert.Equal(expected: false, actual: command?.IncludeBlocked);
    }

    [Theory]
    [InlineData(
        "expected: github open-prs|open-pr-count|branch-requires-status-checks|own-open-prs [options]",
        "github"
    )]
    [InlineData(
        "expected: github open-prs|open-pr-count|branch-requires-status-checks|own-open-prs [options]",
        "gh|open-prs"
    )]
    [InlineData("unknown github read 'pr-list'", "github|pr-list")]
    [InlineData("--repo needs a value", "github|open-prs|--head|main|--repo")]
    [InlineData("unknown option '--branch'", "github|open-prs|--branch|main")]
    [InlineData("unknown option '--head'", "github|branch-requires-status-checks|--head|main")]
    [InlineData("--repo is required", "github|open-prs|--head|main")]
    [InlineData("--repo is required", "github|open-prs|--repo||--head|main")]
    [InlineData("--head is required", "github|open-pr-count|--repo|org/repo")]
    [InlineData("--branch is required", "github|branch-requires-status-checks|--repo|org/repo|--branch|")]
    [InlineData("--me is required", "github|own-open-prs|--repo|org/repo|--creator|app/prpixie")]
    [InlineData("--creator is required", "github|own-open-prs|--repo|org/repo|--me|bot-user")]
    [InlineData("--creator is required", "github|own-open-prs|--repo|org/repo|--me|bot-user|--creator|")]
    [InlineData(
        "--include-blocked must be true or false",
        "github|own-open-prs|--repo|o/r|--me|a|--creator|b|--include-blocked|yes"
    )]
    [InlineData("unknown option '--head'", "github|own-open-prs|--repo|org/repo|--head|main")]
    [InlineData("unknown option '--me'", "github|open-prs|--repo|org/repo|--me|bot-user")]
    public static void AnInvalidCommandIsRefused(string expectedError, string args)
    {
        // The arguments are given joined with '|', so an empty one can be given too
        GitHubCommand? command = GitHubCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.StartsWith(
            expectedStartString: expectedError,
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
    }
}
