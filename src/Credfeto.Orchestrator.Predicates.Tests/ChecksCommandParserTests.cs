using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Predicates.Tests;

public sealed class ChecksCommandParserTests : TestBase
{
    [Theory]
    [InlineData("checks|next-phase|--board-status|AI Review|--required-checks-unknown|false", "NEXT_PHASE")]
    [InlineData("checks|next-phase|--required-checks-unknown||--board-status|", "NEXT_PHASE")]
    [InlineData("checks|merge-state-allows-settled|--merge-state|BEHIND", "MERGE_STATE_ALLOWS_SETTLED")]
    [InlineData(
        "checks|session-progress-reason|--post-head|b|--pre-head|a|--post-comment-ts||--pre-comment-ts||--post-board"
            + "|x|--pre-board|y",
        "SESSION_PROGRESS_REASON"
    )]
    [InlineData("checks|clean-review-comment|--status|AI Coverage", "CLEAN_REVIEW_COMMENT")]
    [InlineData("checks|has-blocked-label", "HAS_BLOCKED_LABEL")]
    [InlineData("checks|priority-for-labels", "PRIORITY_FOR_LABELS")]
    public static void ParsesEachQuery(string args, string expected)
    {
        ChecksCommand? command = ChecksCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.NotNull(command);
        Assert.Equal(expected: expected, actual: command.Query.ToString());
        Assert.Empty(error);
    }

    [Fact]
    public static void KeepsEachOptionsValue()
    {
        ChecksCommand? command = ChecksCommandParser.Parse(
            args: "checks|next-phase|--required-checks-unknown|true|--board-status|Human Review".Split('|'),
            error: out _
        );

        Assert.NotNull(command);
        Assert.Equal(expected: "Human Review", actual: command.Option(ChecksCommandParser.BOARD_STATUS));
        Assert.Equal(expected: "true", actual: command.Option(ChecksCommandParser.REQUIRED_CHECKS_UNKNOWN));
    }

    [Theory]
    [InlineData("checks", "expected: checks <query>")]
    [InlineData("predicate|next-phase", "expected: checks <query>")]
    [InlineData("checks|no-such-query", "unknown checks query 'no-such-query'")]
    [InlineData("checks|next-phase|--board-status|x", "checks next-phase needs --board-status <value>")]
    [InlineData("checks|next-phase|--board-status|x|--board-status|y", "checks next-phase needs")]
    [InlineData("checks|next-phase|--board-status|x|--required-checks-unknown", "checks next-phase needs")]
    [InlineData("checks|next-phase|--board-status|x|--required-checks-unknown|y|--extra|z", "needs")]
    [InlineData("checks|merge-state-allows-settled|merge-state|x", "needs --merge-state <value>")]
    [InlineData("checks|has-blocked-label|--json|x", "checks has-blocked-label takes no options")]
    public static void RefusesAnythingElse(string args, string expected)
    {
        ChecksCommand? command = ChecksCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.Contains(expectedSubstring: expected, actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Fact]
    public static void NamesEveryQueryInOrdinalOrder()
    {
        Assert.Equal(
            expected: "clean-review-comment|has-blocked-label|merge-state-allows-settled|next-phase|priority-for-labels"
                + "|session-progress-reason",
            actual: string.Join(separator: '|', values: ChecksCommandParser.Names)
        );
    }

    [Theory]
    [InlineData("NEXT_PHASE", true)]
    [InlineData("MERGE_STATE_ALLOWS_SETTLED", true)]
    [InlineData("HAS_BLOCKED_LABEL", true)]
    [InlineData("PRIORITY_FOR_LABELS", true)]
    [InlineData("SESSION_PROGRESS_REASON", false)]
    [InlineData("CLEAN_REVIEW_COMMENT", false)]
    public static void OnlyTheJsonReadsReadStdin(string query, bool expected)
    {
        Assert.Equal(expected: expected, actual: ChecksCommandParser.ReadsInput(Enum.Parse<ChecksQuery>(query)));
    }
}
