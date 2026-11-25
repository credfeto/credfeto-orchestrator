using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class TrustedLoginsTests : TestBase
{
    [Fact]
    public static void TheListIsSortedUniqueAndIndentedAsJqPrintsIt()
    {
        string trusted = TrustedLogins.Build(
            owner: "org",
            collaborators: ["zed", "org", "Alice"],
            whitelist: " friend ,zed",
            creator: "prpixie"
        );

        Assert.Equal(
            expected: "[\n  \"Alice\",\n  \"copilot-pull-request-reviewer\",\n  \"friend\",\n"
                + "  \"github-advanced-security[bot]\",\n  \"org\",\n  \"zed\"\n]",
            actual: trusted
        );
    }

    [Fact]
    public static void TheCreatorIsNeverTrusted()
    {
        string trusted = TrustedLogins.Build(
            owner: "prpixie",
            collaborators: ["prpixie"],
            whitelist: "prpixie",
            creator: "prpixie"
        );

        Assert.Equal(
            expected: "[\n  \"copilot-pull-request-reviewer\",\n  \"github-advanced-security[bot]\"\n]",
            actual: trusted
        );
    }

    [Fact]
    public static void EmptyLoginsAndLinesAreSkipped()
    {
        string trusted = TrustedLogins.Build(
            owner: string.Empty,
            collaborators: [string.Empty, "a\nb"],
            whitelist: string.Empty,
            creator: "github-advanced-security[bot]"
        );

        Assert.Equal(expected: "[\n  \"a\",\n  \"b\",\n  \"copilot-pull-request-reviewer\"\n]", actual: trusted);
    }

    [Theory]
    [InlineData("", "")]
    [InlineData("a", "a")]
    [InlineData(" a , b ,, ,c", "a|b|c")]
    [InlineData("\ta\t", "\ta\t")]
    public static void TheWhitelistIsSplitOnCommasAndTrimmedOfSpaces(string whitelist, string expected)
    {
        Assert.Equal(
            expected: expected,
            actual: string.Join(separator: '|', values: TrustedLogins.Whitelisted(whitelist))
        );
    }
}
