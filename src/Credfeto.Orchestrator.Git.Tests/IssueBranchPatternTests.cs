using System.Text;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Git.Tests;

public sealed class IssueBranchPatternTests : TestBase
{
    [Theory]
    [InlineData("feat/12", "12", StaleBranchMatch.MATCH)]
    [InlineData("feat/12-x", "12", StaleBranchMatch.MATCH)]
    [InlineData("Feat/12_x", "12", StaleBranchMatch.MATCH)]
    [InlineData("feat/12/x", "12", StaleBranchMatch.MATCH)]
    [InlineData("feat/120", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("feat/112", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("feat2/12", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("/12", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("12", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("a/b/12", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("fe-at/12", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("fé/12", "12", StaleBranchMatch.LOCALE_DEPENDENT)]
    [InlineData("fé/120", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("fé/13", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("f-é/12", "12", StaleBranchMatch.NO_MATCH)]
    [InlineData("feat/12²", "12", StaleBranchMatch.LOCALE_DEPENDENT)]
    [InlineData("feat/12-é", "12", StaleBranchMatch.MATCH)]
    [InlineData("feat/1²", "12", StaleBranchMatch.NO_MATCH)]
    public static void TheIssueBranchRegexIsMatchedAsBashMatchesItInEveryLocale(
        string branch,
        string issue,
        StaleBranchMatch expected
    )
    {
        StaleBranchMatch match = IssueBranchPattern.Match(
            branch: Encoding.UTF8.GetBytes(branch),
            issue: Encoding.ASCII.GetBytes(issue)
        );

        Assert.Equal(expected: expected, actual: match);
    }

    [Theory]
    [InlineData("12", true)]
    [InlineData("0", true)]
    [InlineData("", false)]
    [InlineData("1a", false)]
    [InlineData(" 1", false)]
    [InlineData("١", false)]
    public static void AnIssueNumberIsAsciiDigitsOnly(string issue, bool expected)
    {
        Assert.Equal(expected: expected, actual: IssueBranchPattern.IsIssueNumber(issue));
    }
}
