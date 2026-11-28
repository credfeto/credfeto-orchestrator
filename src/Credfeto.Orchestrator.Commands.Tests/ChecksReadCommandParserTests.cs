using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class ChecksReadCommandParserTests : TestBase
{
    [Fact]
    public static void TheRequiredCheckNamesReadTakesARepositoryAndAPullRequestInEitherOrder()
    {
        ChecksReadCommand? command = ChecksReadCommandParser.Parse(
            args: ["checks", "required-check-names", "--pr", "42", "--repo", "org/repo"],
            error: out string error
        );

        Assert.Equal(
            expected: new ChecksReadCommand(
                Read: ChecksRead.REQUIRED_CHECK_NAMES,
                Repository: "org/repo",
                PullRequest: 42,
                Sha: string.Empty
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public static void TheRunningCheckRunReadTakesARepositoryAndACommitEitherOfWhichMayBeEmpty()
    {
        ChecksReadCommand? command = ChecksReadCommandParser.Parse(
            args: ["checks", "has-running-check-runs", "--repo", string.Empty, "--sha", string.Empty],
            error: out string error
        );

        Assert.Equal(
            expected: new ChecksReadCommand(
                Read: ChecksRead.HAS_RUNNING_CHECK_RUNS,
                Repository: string.Empty,
                PullRequest: 0,
                Sha: string.Empty
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("checks|required-check-names|--repo|org/repo", "needs --repo <owner/repo> and --pr <value>")]
    [InlineData("checks|required-check-names|--repo|org/repo|--repo|org/other", "each once")]
    [InlineData("checks|required-check-names|--repo|org/repo|--sha|abc", "needs --repo <owner/repo> and --pr")]
    [InlineData("checks|has-running-check-runs|--repo|org/repo|--pr|7", "needs --repo <owner/repo> and --sha")]
    [InlineData("checks|has-running-check-runs|--repo|org/repo|--sha|abc|--sha", "and nothing else")]
    [InlineData("checks|required-check-names|--repo|org/repo|--pr|seven", "a pull request number, not 'seven'")]
    [InlineData("checks|required-check-names|--repo|org/repo|--pr|0", "a pull request number, not '0'")]
    [InlineData("checks|required-check-names|--repo|org/repo|--pr|+7", "a pull request number, not '+7'")]
    [InlineData("checks|next-phase", "expected: checks <read>")]
    public static void AnythingElseIsAUsageError(string args, string expected)
    {
        ChecksReadCommand? command = ChecksReadCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.Contains(expectedSubstring: expected, actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("checks|required-check-names", true)]
    [InlineData("checks|has-running-check-runs|--repo|r", true)]
    [InlineData("checks|next-phase", false)]
    [InlineData("checks", false)]
    [InlineData("github|required-check-names", false)]
    public static void OnlyTheTwoReadsAreRunWithTheGitHubReader(string args, bool expected)
    {
        Assert.True(
            ChecksReadCommandParser.IsRead(args.Split('|')) == expected,
            userMessage: args + " should " + (expected ? string.Empty : "not ") + "be a GitHub checks read"
        );
    }

    [Fact]
    public static void TheNamesAreTheCapabilitiesListsInOrdinalOrder()
    {
        Assert.Equal(
            expected: ["has-running-check-runs", "required-check-names"],
            actual: ChecksReadCommandParser.Names,
            comparer: StringComparer.Ordinal
        );
    }
}
