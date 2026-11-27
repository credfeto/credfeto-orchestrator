using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

public sealed class PodmanTextCommandParserTests : TestBase
{
    [Theory]
    [InlineData("podman|background-stall|--ctype|C|--collate|C|--pattern|x", PodmanTextQuery.BACKGROUND_STALL)]
    [InlineData("podman|diagnostic-refusal|--pattern|x|--collate||--ctype|", PodmanTextQuery.DIAGNOSTIC_REFUSAL)]
    [InlineData(
        "podman|tool-denied-quit|--ctype|C|--collate|C|--mention|a|--give-up|b|--workaround|c|--negated|d",
        PodmanTextQuery.TOOL_DENIED_QUIT
    )]
    [InlineData(
        "podman|review-result-marker|--ctype|C|--collate|C|--clean-marker|a|--findings-marker|b",
        PodmanTextQuery.REVIEW_RESULT_MARKER
    )]
    [InlineData(
        "podman|clean-review|--ctype|C|--collate|C|--clean-marker|a|--findings-marker|b|--clean|c|--findings|d|--negated|e",
        PodmanTextQuery.CLEAN_REVIEW
    )]
    public static void EachTextQueryTakesItsOptionsInAnyOrder(string args, PodmanTextQuery query)
    {
        string[] split = args.Split('|');

        PodmanTextCommand? command = PodmanTextCommandParser.Parse(args: split, error: out string error);

        Assert.True(condition: PodmanTextCommandParser.IsQuery(split), userMessage: args);
        Assert.NotNull(command);
        Assert.Equal(expected: query, actual: command.Query);
        Assert.Equal(expected: (split.Length - 2) / 2, actual: command.Options.Count);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("podman|background-stall|--ctype|C|--collate|C")]
    [InlineData("podman|background-stall|--ctype|C|--collate|C|--pattern")]
    [InlineData("podman|background-stall|--ctype|C|--collate|C|--pattern|x|--pattern|y")]
    [InlineData("podman|background-stall|--ctype|C|--ctype|C|--pattern|x")]
    [InlineData("podman|background-stall|--ctype|C|--collate|C|--mention|x")]
    [InlineData("podman|background-stall|ctype|C|--collate|C|--pattern|x")]
    [InlineData("podman|review-result-marker|--ctype|C|--collate|C|--clean-marker|a")]
    public static void AnythingElseIsAUsageError(string args)
    {
        PodmanTextCommand? command = PodmanTextCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.StartsWith(
            expectedStartString: "podman " + args.Split('|')[1] + " needs --",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData("podman|image-sha|--image|i")]
    [InlineData("podman")]
    [InlineData("git|background-stall")]
    public static void OtherArgumentsAreNotATextQuery(string args)
    {
        Assert.False(condition: PodmanTextCommandParser.IsQuery(args.Split('|')), userMessage: args);
        Assert.Null(PodmanTextCommandParser.Parse(args: args.Split('|'), error: out string _));
    }
}
