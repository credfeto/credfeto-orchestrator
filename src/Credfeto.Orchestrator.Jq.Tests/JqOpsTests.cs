using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Jq.Tests;

public sealed class JqOpsTests : TestBase
{
    [Fact]
    public static void IndexingANonObjectFails()
    {
        Assert.Throws<JqException>(() => JqOps.Field(value: JqValue.FromString("s"), name: "x"));
        Assert.Same(expected: JqValue.Null, actual: JqOps.Field(value: JqValue.Null, name: "x"));
    }

    [Fact]
    public static void IndexingAnObjectFindsTheField()
    {
        JqValue item = JqParser.Parse("""{"a":"x","b":null}""");

        Assert.Equal(expected: "x", actual: JqOps.Field(value: item, name: "a").Text);
        Assert.Same(expected: JqValue.Null, actual: JqOps.Field(value: item, name: "b"));
        Assert.Same(expected: JqValue.Null, actual: JqOps.Field(value: item, name: "missing"));
    }

    [Fact]
    public static void TheAlternativeOperatorReplacesOnlyNullAndFalse()
    {
        JqValue zero = JqValue.FromNumberLiteral("0");
        JqValue empty = JqValue.FromString(string.Empty);

        Assert.Same(expected: zero, actual: JqOps.Alternative(value: zero, fallback: JqValue.True));
        Assert.Same(expected: empty, actual: JqOps.Alternative(value: empty, fallback: "none"));
        Assert.Same(expected: JqValue.True, actual: JqOps.Alternative(value: JqValue.False, fallback: JqValue.True));
        Assert.Equal(expected: "none", actual: JqOps.Alternative(value: JqValue.Null, fallback: "none").Text);
    }

    [Fact]
    public static void IteratingAnObjectYieldsItsValuesInOrder()
    {
        JqValue values = JqOps.Filter(
            value: JqParser.Parse("""{"b":2,"a":1,"c":3}"""),
            predicate: static value => value.Number > 1
        );

        Assert.Equal(expected: """[2,3]""", actual: JqFormatter.ToJson(values));
    }

    [Fact]
    public static void SortByIsStableAndLastTakesTheFinalItem()
    {
        JqValue items = JqParser.Parse("""[{"k":2,"n":"a"},{"k":1,"n":"b"},{"k":2,"n":"c"},{"n":"d"}]""");

        JqValue sorted = JqOps.SortBy(value: items, key: static item => JqOps.Field(value: item, name: "k"));

        Assert.Equal(
            expected: """[{"n":"d"},{"k":1,"n":"b"},{"k":2,"n":"a"},{"k":2,"n":"c"}]""",
            actual: JqFormatter.ToJson(sorted)
        );
        Assert.Equal(expected: "c", actual: JqOps.Field(value: JqOps.Last(sorted), name: "n").Text);
    }

    [Fact]
    public static void IteratingAScalarFails()
    {
        Assert.Throws<JqException>(() => JqOps.Iterate(JqValue.Null));
        Assert.Throws<JqException>(() => JqOps.Iterate(JqValue.FromString("s")));
    }

    [Theory]
    [InlineData("""null""", "0")]
    [InlineData("""-5""", "5")]
    [InlineData("""5.50""", "5.50")]
    [InlineData("\"h\u00e9llo\"", "5")]
    [InlineData("\"\\ud83d\\ude00\"", "1")]
    [InlineData("""[1,2]""", "2")]
    [InlineData("""{"a":1}""", "1")]
    public static void LengthFollowsJq(string json, string expected)
    {
        Assert.Equal(expected: expected, actual: JqOps.ToText(JqOps.Length(JqParser.Parse(json))));
    }

    [Fact]
    public static void BooleansHaveNoLength()
    {
        Assert.Throws<JqException>(() => JqOps.Length(JqValue.True));
    }

    [Fact]
    public static void LastOfAnObjectFails()
    {
        Assert.Throws<JqException>(() => JqOps.Last(JqParser.Parse("""{"a":1}""")));
        Assert.Same(expected: JqValue.Null, actual: JqOps.Last(JqValue.Null));
        Assert.Same(expected: JqValue.Null, actual: JqOps.Last(JqValue.EmptyArray));
    }

    [Fact]
    public static void SortByNeedsAnArray()
    {
        Assert.Throws<JqException>(() => JqOps.SortBy(value: JqValue.Null, key: static value => value));
    }

    [Fact]
    public static void TsvEscapesAndRejectsContainers()
    {
        Assert.Equal(
            expected: "\ttrue\t1.50\ta\\tb\\\\c\\nd\\re",
            actual: JqOps.Tsv([
                JqValue.Null,
                JqValue.True,
                JqValue.FromNumberLiteral("1.50"),
                JqValue.FromString("a\tb\\c\nd\re"),
            ])
        );
        Assert.Equal(expected: "a\\0b", actual: JqOps.Tsv([JqValue.FromString("a\0b")]));
        Assert.Throws<JqException>(() => JqOps.Tsv([JqValue.EmptyArray]));
    }

    [Fact]
    public static void JoinFormatsScalarsAndRejectsContainers()
    {
        Assert.Equal(
            expected: ",b,true,1E+2",
            actual: JqOps.Join(
                values: [JqValue.Null, JqValue.FromString("b"), JqValue.True, JqValue.FromNumberLiteral("1e2")],
                separator: ","
            )
        );
        Assert.Equal(expected: string.Empty, actual: JqOps.Join(values: [], separator: ","));
        Assert.Throws<JqException>(() => JqOps.Join(values: [JqValue.FromObject([])], separator: ","));
    }

    [Fact]
    public static void ContainsNeedsAnArrayOfTrustedLogins()
    {
        Assert.True(
            JqOps.Contains(values: JqParser.Parse("""["a","b"]"""), item: JqValue.FromString("b")),
            userMessage: "b is in the list"
        );
        Assert.False(
            JqOps.Contains(values: JqParser.Parse("""["a"]"""), item: JqValue.Null),
            userMessage: "A missing login is never trusted"
        );
        Assert.Throws<JqException>(() =>
            JqOps.Contains(values: JqValue.FromString("a"), item: JqValue.FromString("a"))
        );
    }

    [Fact]
    public static void ToJsonEscapesLikeJq()
    {
        Assert.Equal(
            expected: """{"a":[1.0,null,true,false],"b":"q\"\\\n\t\r\b\f\u0001\u007fé"}""",
            actual: JqFormatter.ToJson(
                JqParser.Parse("{\"a\":[1.0,null,true,false],\"b\":\"q\\\"\\\\\\n\\t\\r\\b\\f\\u0001\\u007fé\"}")
            )
        );
    }

    [Fact]
    public static void RepeatedKeysKeepTheirFirstPositionAndLastValue()
    {
        Assert.Equal(
            expected: """{"b":3,"a":1}""",
            actual: JqFormatter.ToJson(JqParser.Parse("""{"b":2,"a":1,"b":3}"""))
        );
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("")]
    [InlineData("{} {}")]
    public static void InvalidJsonFails(string json)
    {
        Assert.Throws<JqException>(() => JqParser.Parse(json));
    }

    [Fact]
    public static void TypeNamesFollowJq()
    {
        Assert.Equal(expected: "boolean", actual: JqValue.FromBoolean(false).TypeName());
        Assert.Equal(expected: "boolean", actual: JqValue.FromBoolean(true).TypeName());
        Assert.Equal(expected: "number", actual: JqValue.FromInteger(3).TypeName());
    }
}
