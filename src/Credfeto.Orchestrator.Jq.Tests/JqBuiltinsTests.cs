using System.Linq;
using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Jq.Tests;

public sealed class JqBuiltinsTests : TestBase
{
    [Fact]
    public static void EqualityUsesJqsOrder()
    {
        Assert.True(
            condition: JqBuiltins.Equal(left: JqParser.Parse("1"), right: JqParser.Parse("1.0")),
            userMessage: "1 == 1.0"
        );
        Assert.False(
            condition: JqBuiltins.Equal(left: JqParser.Parse("\"1\""), right: JqParser.Parse("1")),
            userMessage: "\"1\" != 1"
        );
        Assert.True(
            condition: JqBuiltins.Equal(left: JqParser.Parse("\"a\""), right: "a"),
            userMessage: "a string equals its text"
        );
        Assert.False(
            condition: JqBuiltins.Equal(left: JqValue.Null, right: string.Empty),
            userMessage: "null is not the empty string"
        );
    }

    [Fact]
    public static void OptionalIterationSkipsWhatCannotBeIterated()
    {
        Assert.Empty(JqBuiltins.IterateOptional(JqValue.FromString("x")));
        Assert.Empty(JqBuiltins.IterateOptional(JqValue.Null));
        Assert.Equal(expected: 2, actual: JqBuiltins.IterateOptional(JqParser.Parse("""{"a":1,"b":2}""")).Count);
    }

    [Fact]
    public static void AsciiDowncaseLeavesOtherLettersAlone()
    {
        Assert.Equal(expected: "abc-İK", actual: JqBuiltins.AsciiDowncase(JqValue.FromString("AbC-İK")).Text);
        Assert.Throws<JqException>(() => JqBuiltins.AsciiDowncase(JqValue.Null));
    }

    [Fact]
    public static void SplitGivesNoPartsForAnEmptyString()
    {
        Assert.Empty(JqBuiltins.Split(value: JqValue.FromString(string.Empty), separator: "\n"));
        Assert.Equal(
            expected: "a||b|",
            actual: string.Join(
                separator: '|',
                values: JqBuiltins
                    .Split(value: JqValue.FromString("a\n\nb\n"), separator: "\n")
                    .Select(static part => part.Text)
            )
        );
        Assert.Throws<JqException>(() => JqBuiltins.Split(value: JqParser.Parse("5"), separator: "\n"));
    }

    [Fact]
    public static void RTrimStrRemovesOneSuffixAndNeedsAString()
    {
        Assert.Equal(
            expected: "a\r",
            actual: JqBuiltins.RTrimStr(value: JqValue.FromString("a\r\r"), suffix: "\r").Text
        );
        Assert.Equal(expected: "a", actual: JqBuiltins.RTrimStr(value: JqValue.FromString("a"), suffix: "\r").Text);
        Assert.Throws<JqException>(() => JqBuiltins.RTrimStr(value: JqParser.Parse("5"), suffix: "\r"));
        Assert.Throws<JqException>(() => JqBuiltins.EndsWith(value: JqValue.Null, suffix: "x"));
    }

    [Fact]
    public static void TakeCutsStringsByCodePoint()
    {
        Assert.Equal(
            expected: "\U0001F600é",
            actual: JqBuiltins.Take(value: JqValue.FromString("\U0001F600éx"), count: 2).Text
        );
        Assert.Equal(
            expected: "[1]",
            actual: JqFormatter.ToJson(JqBuiltins.Take(value: JqParser.Parse("[1,2]"), count: 1))
        );
        Assert.Same(expected: JqValue.Null, actual: JqBuiltins.Take(value: JqValue.Null, count: 1));
        Assert.Throws<JqException>(() => JqBuiltins.Take(value: JqParser.Parse("5"), count: 1));
        Assert.Equal(
            expected: "[2]",
            actual: JqFormatter.ToJson(JqBuiltins.Skip(value: JqParser.Parse("[1,2]"), start: 1))
        );
        Assert.Same(expected: JqValue.Null, actual: JqBuiltins.Skip(value: JqValue.Null, start: 1));
        Assert.Throws<JqException>(() => JqBuiltins.Skip(value: JqValue.FromString("ab"), start: 1));
    }

    [Theory]
    [InlineData("[\"a\",\"b\"]", "\"b\"", true)]
    [InlineData("[\"a\",\"b\"]", "\"c\"", false)]
    [InlineData("[1,2,1,2]", "[2,1]", true)]
    [InlineData("[[1],2]", "[1]", false)]
    [InlineData("[1]", "[]", false)]
    [InlineData("\"owner,reviewer\"", "\"own\"", true)]
    [InlineData("\"owner\"", "\"\"", false)]
    [InlineData("{\"a\":[1]}", "\"a\"", true)]
    [InlineData("{\"a\":[]}", "\"a\"", false)]
    [InlineData("{\"a\":1}", "\"b\"", false)]
    [InlineData("null", "\"a\"", false)]
    public static void HasIndexFollowsJqsIndices(string value, string item, bool expected)
    {
        Assert.Equal(
            expected: expected,
            actual: JqBuiltins.HasIndex(value: JqParser.Parse(value), item: JqParser.Parse(item))
        );
    }

    [Theory]
    [InlineData("\"owner\"", "null")]
    [InlineData("5", "\"a\"")]
    [InlineData("{\"a\":1}", "\"a\"")]
    [InlineData("{\"a\":1}", "1")]
    [InlineData("true", "\"a\"")]
    public static void HasIndexFailsWhereJqFails(string value, string item)
    {
        Assert.Throws<JqException>(() => JqBuiltins.HasIndex(value: JqParser.Parse(value), item: JqParser.Parse(item)));
    }

    [Fact]
    public static void GroupByAndUniqueByAreStable()
    {
        JqValue items = JqParser.Parse("""[{"k":2,"n":"a"},{"k":1,"n":"b"},{"k":2,"n":"c"}]""");

        string groups = string.Join(
            separator: ';',
            values: JqBuiltins
                .GroupBy(value: items, key: static item => JqOps.Field(value: item, name: "k"))
                .Select(static group =>
                    string.Concat(group.Select(static item => JqOps.Field(value: item, name: "n").Text))
                )
        );
        string unique = string.Concat(
            JqBuiltins
                .UniqueBy(value: items, key: static item => JqOps.Field(value: item, name: "k"))
                .Select(static item => JqOps.Field(value: item, name: "n").Text)
        );

        Assert.Equal(expected: "b;ac", actual: groups);
        Assert.Equal(expected: "ba", actual: unique);
        Assert.Throws<JqException>(() =>
            JqBuiltins.GroupBy(value: JqParser.Parse("""{"a":1}"""), key: static item => item)
        );
        Assert.Throws<JqException>(() => JqBuiltins.GroupBy(value: JqValue.Null, key: static item => item));
    }

    [Fact]
    public static void MinKeepsTheFirstOfEqualItems()
    {
        Assert.Equal(expected: "2.0", actual: JqBuiltins.Min(JqParser.Parse("[3,2.0,2]")).Text);
        Assert.Same(expected: JqValue.Null, actual: JqBuiltins.Min(JqValue.EmptyArray));
        Assert.Throws<JqException>(() => JqBuiltins.Min(JqValue.Null));
    }

    [Fact]
    public static void AddFollowsJqForTheOperandsThePredicatesUse()
    {
        Assert.Equal(expected: "ab", actual: JqBuiltins.Add(left: "a", right: JqValue.FromString("b")).Text);
        Assert.Equal(
            expected: "[1,2]",
            actual: JqFormatter.ToJson(JqBuiltins.Add(left: JqParser.Parse("[1]"), right: JqParser.Parse("[2]")))
        );
        Assert.Equal(
            expected: """{"a":3,"b":2}""",
            actual: JqFormatter.ToJson(
                JqBuiltins.Add(left: JqParser.Parse("""{"a":1,"b":2}"""), right: JqParser.Parse("""{"a":3}"""))
            )
        );
        Assert.Equal(expected: "x", actual: JqBuiltins.Add(left: JqValue.Null, right: JqValue.FromString("x")).Text);
        Assert.Equal(expected: "x", actual: JqBuiltins.Add(left: JqValue.FromString("x"), right: JqValue.Null).Text);
        Assert.Throws<JqException>(() => JqBuiltins.Add(left: "a", right: JqParser.Parse("1")));
    }

    [Fact]
    public static void SetFieldKeepsTheKeysPlace()
    {
        Assert.Equal(
            expected: """{"b":true,"a":2}""",
            actual: JqFormatter.ToJson(
                JqBuiltins.SetField(value: JqParser.Parse("""{"b":1,"a":2}"""), name: "b", field: JqValue.True)
            )
        );
        Assert.Equal(
            expected: """{"c":true}""",
            actual: JqFormatter.ToJson(JqBuiltins.SetField(value: JqValue.Null, name: "c", field: JqValue.True))
        );
        Assert.Throws<JqException>(() =>
            JqBuiltins.SetField(value: JqValue.FromString("x"), name: "c", field: JqValue.True)
        );
        Assert.Equal(
            expected: """[1]""",
            actual: JqFormatter.ToJson(
                JqBuiltins.Map(value: JqParser.Parse("""{"a":1}"""), selector: static item => item)
            )
        );
        Assert.True(
            condition: JqBuiltins.IsKind(value: JqValue.EmptyArray, typeName: "array"),
            userMessage: "[] is an array"
        );
    }

    [Fact]
    public static void AStreamHoldsEveryJsonTextBeforeTheFirstBadOne()
    {
        JqInput whole = JqParser.ParseStream("{\"a\":1} [2]\n\"x\"");
        JqInput broken = JqParser.ParseStream("{\"a\":1} oops [2]");
        JqInput empty = JqParser.ParseStream("  \n");

        Assert.Equal(expected: 3, actual: whole.Values.Count);
        Assert.True(condition: whole.Complete, userMessage: "every text was read");
        Assert.Single(broken.Values);
        Assert.False(condition: broken.Complete, userMessage: "the input stopped at a bad text");
        Assert.Empty(empty.Values);
        Assert.True(condition: empty.Complete, userMessage: "white space alone is a complete input");
    }
}
