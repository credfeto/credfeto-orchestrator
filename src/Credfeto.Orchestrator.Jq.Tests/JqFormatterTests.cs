using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Jq.Tests;

public sealed class JqFormatterTests : TestBase
{
    // What jq 1.8 prints for the value built below: nested, with an empty array and object and a DEL character
    private const string INDENTED = """
        {
          "a": [
            1,
            {}
          ],
          "b": {
            "c": [],
            "d": "x\u007f"
          },
          "e": null
        }
        """;

    [Fact]
    public static void NestedValuesIndentAsJqPrintsThem()
    {
        JqValue value = JqValue.FromObject([
            new(Name: "a", Value: JqValue.FromArray([JqValue.FromInteger(1), JqValue.FromObject([])])),
            new(
                Name: "b",
                Value: JqValue.FromObject([
                    new(Name: "c", Value: JqValue.EmptyArray),
                    new(Name: "d", Value: JqValue.FromString("x\u007f")),
                ])
            ),
            new(Name: "e", Value: JqValue.Null),
        ]);

        Assert.Equal(expected: INDENTED, actual: JqFormatter.ToIndentedJson(value));
    }

    [Fact]
    public static void AScalarPrintsAsCompactJson()
    {
        Assert.Equal(expected: "\"a\\tb\"", actual: JqFormatter.ToIndentedJson(JqValue.FromString("a\tb")));
        Assert.Equal(expected: "[]", actual: JqFormatter.ToIndentedJson(JqValue.EmptyArray));
        Assert.Equal(expected: "true", actual: JqFormatter.ToIndentedJson(JqValue.True));
    }
}
