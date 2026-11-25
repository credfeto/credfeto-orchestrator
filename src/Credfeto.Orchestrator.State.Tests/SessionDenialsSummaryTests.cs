using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

public sealed class SessionDenialsSummaryTests : TestBase
{
    [Fact]
    public static void AnEmptyDayHasNothingInIt()
    {
        Assert.Equal(
            expected: """{"sessions":0,"denials":0,"stalled":0,"quits":0,"repos":[],"top_commands":[]}""",
            actual: SessionDenialsSummary.Summarise(string.Empty)
        );
    }

    [Fact]
    public static void RepositoriesComeMostDeniedFirstThenByName()
    {
        string day =
            Line(repo: "o/b", denials: "1", stalled: "1", commands: "git")
            + Line(repo: "o/a", denials: "3", stalled: "0", commands: "cat,git")
            + Line(repo: "o/c", denials: "1", stalled: "0", commands: "-")
            + Line(repo: "o/B", denials: "1", stalled: "1", commands: "");

        Assert.Equal(
            expected: """{"sessions":4,"denials":6,"stalled":2,"quits":0,"repos":["""
                + """{"repo":"o/a","sessions":1,"denials":3,"stalled":0},"""
                + """{"repo":"o/B","sessions":1,"denials":1,"stalled":1},"""
                + """{"repo":"o/b","sessions":1,"denials":1,"stalled":1},"""
                + """{"repo":"o/c","sessions":1,"denials":1,"stalled":0}],"""
                + """ "top_commands":[{"name":"git","count":2},{"name":"cat","count":1}]}""".TrimStart(),
            actual: SessionDenialsSummary.Summarise(day)
        );
    }

    [Theory]
    [InlineData("1e2")]
    [InlineData("nan")]
    [InlineData("-inf")]
    [InlineData(" 5")]
    [InlineData("1234567890123456")]
    public static void ADenialCountJqMayReadDifferentlyIsRefused(string denials)
    {
        string day = Line(repo: "o/a", denials: denials, stalled: "0", commands: "-");

        Assert.Throws<StateRefusedException>(() => SessionDenialsSummary.Summarise(day));
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("")]
    [InlineData("-")]
    [InlineData("x y")]
    public static void ADenialCountJqCannotReadIsZero(string denials)
    {
        string day = Line(repo: "o/a", denials: denials, stalled: "0", commands: "-");

        Assert.StartsWith(
            expectedStartString: """{"sessions":1,"denials":0,""",
            actualString: SessionDenialsSummary.Summarise(day),
            comparisonType: System.StringComparison.Ordinal
        );
    }

    private static string Line(string repo, string denials, string stalled, string commands)
    {
        return string.Join(
                separator: '\t',
                "2026-11-24T10:00:00+00:00",
                repo,
                "Issue",
                "1",
                denials,
                stalled,
                "0",
                commands
            ) + "\n";
    }
}
