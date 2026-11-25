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

    [Fact]
    public static void TheCurrentLoginReadTakesNoOptions()
    {
        GitHubCommand? command = GitHubCommandParser.Parse(args: ["github", "whoami"], error: out string error);

        Assert.Equal(
            expected: new GitHubCommand(Read: GitHubRead.CURRENT_LOGIN, Repository: string.Empty, Name: string.Empty),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public static void TheClosingIssuesReadTakesTheRepository()
    {
        GitHubCommand? command = GitHubCommandParser.Parse(
            args: ["github", "open-prs-closing-issues", "--repo", "org/repo"],
            error: out string error
        );

        Assert.Equal(
            expected: new GitHubCommand(
                Read: GitHubRead.OPEN_PULL_REQUESTS_WITH_CLOSING_ISSUES,
                Repository: "org/repo",
                Name: string.Empty
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("7", 7)]
    [InlineData("123456789", 123456789)]
    public static void TheCommitAuthorsReadTakesTheRepositoryAndPullRequest(string value, int expected)
    {
        GitHubCommand? command = GitHubCommandParser.Parse(
            args: ["github", "pr-commit-authors", "--pr", value, "--repo", "org/repo"],
            error: out string error
        );

        Assert.Equal(
            expected: new GitHubCommand(
                Read: GitHubRead.PULL_REQUEST_COMMIT_AUTHORS,
                Repository: "org/repo",
                Name: string.Empty,
                PullRequest: expected
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public static void TheBehindByReadTakesTheRepositoryBaseAndHead()
    {
        GitHubCommand? command = GitHubCommandParser.Parse(
            args: ["github", "branch-behind-by", "--head", "fix/7-typo", "--repo", "org/repo", "--base", "main"],
            error: out string error
        );

        Assert.Equal(
            expected: new GitHubCommand(
                Read: GitHubRead.BRANCH_BEHIND_BY,
                Repository: "org/repo",
                Name: "fix/7-typo",
                Base: "main"
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("expected: github <read> [options], where <read> is open-prs,", "github")]
    [InlineData("expected: github <read> [options], where <read> is open-prs,", "gh|open-prs")]
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
    [InlineData("unknown option '--repo'", "github|whoami|--repo|org/repo")]
    [InlineData("--repo is required", "github|open-prs-closing-issues")]
    [InlineData("unknown option '--head'", "github|open-prs-closing-issues|--repo|org/repo|--head|main")]
    [InlineData("--pr is required", "github|pr-commit-authors|--repo|org/repo")]
    [InlineData("--pr must be a pull request number", "github|pr-commit-authors|--repo|org/repo|--pr|12a")]
    [InlineData("--pr must be a pull request number", "github|pr-commit-authors|--repo|org/repo|--pr|-3")]
    [InlineData("--pr must be a pull request number", "github|pr-commit-authors|--repo|org/repo|--pr|0")]
    [InlineData("--pr must be a pull request number", "github|pr-commit-authors|--repo|org/repo|--pr|012")]
    [InlineData("--pr must be a pull request number", "github|pr-commit-authors|--repo|org/repo|--pr|1234567890")]
    [InlineData("--pr must be a pull request number", "github|pr-commit-authors|--repo|org/repo|--pr| 7")]
    [InlineData("--base is required", "github|branch-behind-by|--repo|org/repo|--head|fix/7-typo")]
    [InlineData("--head is required", "github|branch-behind-by|--repo|org/repo|--base|main")]
    [InlineData("unknown option '--branch'", "github|branch-behind-by|--repo|org/repo|--branch|main")]
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
