using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Jq.Tests;

public sealed class JqStringDecoderTests : TestBase
{
    // Strings System.Text.Json refuses for an unpaired surrogate; jq reads a lone low surrogate as U+FFFD
    [Theory]
    [InlineData("\"\\udc00\"", "\uFFFD")]
    [InlineData("\"x\\udc00y\\n\\t\\r\\b\\f\\\"\\\\\\/\\u0041\"", "x\uFFFDy\n\t\r\b\f\"\\/A")]
    [InlineData("\"\\ud83d\\ude00\\udc00\"", "\U0001F600\uFFFD")]
    [InlineData("\"\u00e9\\udc00\"", "\u00e9\uFFFD")]
    public static void LoneLowSurrogatesBecomeTheReplacementCharacter(string json, string expected)
    {
        Assert.Equal(expected: expected, actual: JqParser.Parse(json).Text);
    }

    // jq refuses a high surrogate that is not followed by a low surrogate escape
    [Theory]
    [InlineData("\"\\ud800\"")]
    [InlineData("\"\\ud800x\\udc00\"")]
    [InlineData("\"\\ud800\\u0041\\udc00\"")]
    [InlineData("\"\\udc00\\ud800\"")]
    public static void UnpairedHighSurrogatesFail(string json)
    {
        Assert.Throws<JqException>(() => JqParser.Parse(json));
    }

    // jq reads an unpaired low surrogate in a key as U+FFFD too; System.Text.Json refuses to name
    // the property, so the fingerprint fails instead. GitHub never sends such a key.
    [Fact]
    public static void AnUnpairedSurrogateInAKeyFails()
    {
        Assert.Throws<JqException>(() => JqParser.Parse("{\"\\udc00\":1}"));
    }
}
