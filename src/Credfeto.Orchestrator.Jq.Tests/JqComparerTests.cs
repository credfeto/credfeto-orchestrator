using System;
using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Jq.Tests;

public sealed class JqComparerTests : TestBase
{
    [Fact]
    public static void KindsSortInJqOrder()
    {
        JqValue[] values =
        [
            JqValue.FromObject([]),
            JqValue.FromArray([]),
            JqValue.FromString("a"),
            JqValue.FromNumberLiteral("1"),
            JqValue.True,
            JqValue.False,
            JqValue.Null,
        ];

        IReadOnlyList<JqValue> sorted = JqOps.Sort(values);

        Assert.Equal(
            expected:
            [
                JqKind.NULL,
                JqKind.FALSE,
                JqKind.TRUE,
                JqKind.NUMBER,
                JqKind.TEXT,
                JqKind.ARRAY,
                JqKind.DICTIONARY,
            ],
            actual: sorted.Select(static value => value.Kind)
        );
    }

    [Fact]
    public static void StringsSortByCodePointNotUtf16()
    {
        // U+FF5E sorts before U+1F600 by code point, but after it by UTF-16 code unit
        IReadOnlyList<JqValue> sorted = JqOps.Sort([
            JqValue.FromString("\U0001F600"),
            JqValue.FromString("\uFF5E"),
            JqValue.FromString("A"),
        ]);

        Assert.Equal(
            expected: ["A", "\uFF5E", "\U0001F600"],
            actual: sorted.Select(static value => value.Text),
            comparer: StringComparer.Ordinal
        );
    }

    [Fact]
    public static void NumbersSortNumerically()
    {
        IReadOnlyList<JqValue> sorted = JqOps.Sort([
            JqValue.FromNumberLiteral("10"),
            JqValue.FromNumberLiteral("2"),
            JqValue.FromNumberLiteral("1.0"),
        ]);

        Assert.Equal(
            expected: ["1.0", "2", "10"],
            actual: sorted.Select(static value => value.Text),
            comparer: StringComparer.Ordinal
        );
    }

    [Fact]
    public static void ArraysSortElementByElementThenByLength()
    {
        JqValue shortArray = JqValue.FromArray([JqValue.FromNumberLiteral("1")]);
        JqValue longArray = JqValue.FromArray([JqValue.FromNumberLiteral("1"), JqValue.FromNumberLiteral("0")]);
        JqValue larger = JqValue.FromArray([JqValue.FromNumberLiteral("2")]);

        IReadOnlyList<JqValue> sorted = JqOps.Sort([larger, longArray, shortArray]);

        Assert.Equal(expected: [shortArray, longArray, larger], actual: sorted);
    }

    [Fact]
    public static void ObjectsSortByTheirKeysThenTheirValues()
    {
        JqValue a2 = Object("a", "2");
        JqValue a1 = Object("a", "1");
        JqValue b0 = Object("b", "0");

        IReadOnlyList<JqValue> sorted = JqOps.Sort([b0, a2, a1]);

        Assert.Equal(expected: [a1, a2, b0], actual: sorted);
        Assert.Equal(expected: 0, actual: JqComparer.Instance.Compare(x: Object("a", "1"), y: a1));
    }

    [Fact]
    public static void NullReferencesSortFirst()
    {
        Assert.Equal(expected: 0, actual: JqComparer.Instance.Compare(x: null, y: null));
        Assert.True(
            JqComparer.Instance.Compare(x: null, y: JqValue.Null) < 0,
            userMessage: "A null reference sorts before any value"
        );
        Assert.True(
            JqComparer.Instance.Compare(x: JqValue.Null, y: null) > 0,
            userMessage: "Any value sorts after a null reference"
        );
        Assert.Equal(expected: 0, actual: JqStringComparer.Instance.Compare(x: null, y: string.Empty));
        Assert.Equal(expected: 0, actual: JqComparer.Instance.Compare(x: JqValue.True, y: JqValue.FromBoolean(true)));
    }

    private static JqValue Object(string key, string number)
    {
        return JqValue.FromObject([new(Name: key, Value: JqValue.FromNumberLiteral(number))]);
    }
}
