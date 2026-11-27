using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Install.Tests;

public sealed class SelfCommandParserTests : TestBase
{
    [Theory]
    [InlineData("--version", SelfQuery.VERSION)]
    [InlineData("--self-test", SelfQuery.SELF_TEST)]
    [InlineData("--capabilities", SelfQuery.CAPABILITIES)]
    public static void EachFlagIsItsQuery(string args, SelfQuery expected)
    {
        SelfQuery? query = SelfCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Equal(expected: expected, actual: query);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("", "expected: --version, --self-test or --capabilities")]
    [InlineData("git|head-sha", "expected: --version, --self-test or --capabilities")]
    [InlineData("--Version", "expected: --version, --self-test or --capabilities")]
    [InlineData("--version|--self-test", "--version takes no arguments")]
    [InlineData("--self-test|config", "--self-test takes no arguments")]
    [InlineData("--self-test|", "--self-test takes no arguments")]
    [InlineData("--capabilities|git", "--capabilities takes no arguments")]
    public static void AnythingElseIsAUsageError(string args, string expected)
    {
        SelfQuery? query = SelfCommandParser.Parse(
            args: args.Length == 0 ? [] : args.Split('|'),
            error: out string error
        );

        Assert.Null(query);
        Assert.Equal(expected: expected, actual: error);
    }

    [Theory]
    [InlineData("--version", true)]
    [InlineData("--self-test|extra", true)]
    [InlineData("--capabilities", true)]
    [InlineData("--versions", false)]
    [InlineData("prompt|--version", false)]
    [InlineData("", false)]
    public static void TheVerbIsEitherFlagFirst(string args, bool expected)
    {
        Assert.Equal(
            expected: expected,
            actual: SelfCommandParser.IsVerb(args.Length == 0 ? [] : args.Split('|', StringSplitOptions.None))
        );
    }
}
