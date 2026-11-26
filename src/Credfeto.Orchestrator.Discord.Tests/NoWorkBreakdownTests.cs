using System.Linq;
using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class NoWorkBreakdownTests : TestBase
{
    [Theory]
    [InlineData("", "")]
    [InlineData("[]", "")]
    [InlineData(
        """[{"type":"Issue","id":"1","repo":"o/r","reason":"x"}]""",
        "- [Issue #1 in o/r](https://github.com/o/r/issues/1): x"
    )]
    [InlineData(
        """[{"type":"PullRequest","id":2,"repo":"o/r","reason":null}]""",
        "- [PullRequest #2 in o/r](https://github.com/o/r/pull/2): "
    )]
    [InlineData(
        """[{"type":"","id":"5","repo":"o/r","reason":"why"}]""",
        "- [5 #o/r in why](https://github.com/why): "
    )]
    [InlineData("""[{"type":"Issue","id":"5"}]""", "- [Issue #5 in ](https://github.com/d/r/issues/5): ")]
    [InlineData("[null]", "- [ # in ](https://github.com/d/r): ")]
    [InlineData(
        """[{"type":"Other","id":true,"repo":"a\tb","reason":"c\\d\n"}]""",
        "- [Other #true in a\\tb](https://github.com/a\\tb): c\\\\d\\n"
    )]
    public static void EachItemIsOneLine(string items, string expected)
    {
        Assert.Equal(expected: expected, actual: Build(items: items, unit: LengthUnit.CHARACTERS));
    }

    [Fact]
    public static void LinesPastTheBudgetAreCounted()
    {
        string reason = new('x', 3900 - "- [Issue #1 in o/r](https://github.com/o/r/issues/1): ".Length - 1);
        string items =
            "[{\"type\":\"Issue\",\"id\":\"1\",\"repo\":\"o/r\",\"reason\":\""
            + reason
            + "\"},{\"type\":\"Issue\",\"id\":\"2\",\"repo\":\"o/r\",\"reason\":\"y\"},null]";

        string text = Build(items: items, unit: LengthUnit.CHARACTERS);

        Assert.Equal(
            expected: "- [Issue #1 in o/r](https://github.com/o/r/issues/1): "
                + reason
                + "\n... and 2 more (see the journal for full detail)",
            actual: text
        );
    }

    [Fact]
    public static void BytesAreCountedWhereBashCountsBytes()
    {
        string reason = string.Concat(Enumerable.Repeat(element: "\u00E9", count: 2000));
        string items = "[{\"type\":\"Issue\",\"id\":\"1\",\"repo\":\"o/r\",\"reason\":\"" + reason + "\"}]";

        Assert.Equal(
            expected: "- [Issue #1 in o/r](https://github.com/o/r/issues/1): " + reason,
            actual: Build(items: items, unit: LengthUnit.CHARACTERS)
        );
        Assert.Equal(
            expected: "\n... and 1 more (see the journal for full detail)",
            actual: Build(items: items, unit: LengthUnit.BYTES)
        );
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("[] []")]
    [InlineData("""["Issue"]""")]
    [InlineData("[1]")]
    [InlineData("""[{"type":["Issue"]}]""")]
    [InlineData("""[{"reason":{"a":1}}]""")]
    public static void ItemsJqFailsOnOrReadsOtherwiseAreRefused(string items)
    {
        Assert.Throws<DiscordRefusedException>(() => Build(items: items, unit: LengthUnit.CHARACTERS));
    }

    [Theory]
    [InlineData("characters", LengthUnit.CHARACTERS)]
    [InlineData("bytes", LengthUnit.BYTES)]
    public static void TheLengthUnitIsParsed(string unit, LengthUnit expected)
    {
        Assert.Equal(expected: expected, actual: NoWorkBreakdown.ParseUnit(unit));
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("")]
    [InlineData("Bytes")]
    public static void AnyOtherLengthUnitIsRefused(string unit)
    {
        Assert.Throws<DiscordRefusedException>(() => NoWorkBreakdown.ParseUnit(unit));
    }

    private static string Build(string items, LengthUnit unit)
    {
        JqInput input = DiscordTextInput.Json(items);

        return NoWorkBreakdown.Build(input: input, defaultRepo: "d/r", unit: unit);
    }
}
