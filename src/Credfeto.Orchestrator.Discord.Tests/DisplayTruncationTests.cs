using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class DisplayTruncationTests : TestBase
{
    [Theory]
    [InlineData("", "900", "\n")]
    [InlineData("abc", "3", "abc\n")]
    [InlineData("abcd", "3", "abc" + DisplayTruncation.Notice + "\n")]
    [InlineData("abc", "0", DisplayTruncation.Notice + "\n")]
    [InlineData("", "0", "\n")]
    [InlineData("\u00E9\U0001F600x", "2", "\u00E9\U0001F600" + DisplayTruncation.Notice + "\n")]
    [InlineData("\U0001F600\U0001F600", "2", "\U0001F600\U0001F600\n")]
    [InlineData("a\n\n", "900", "a\n\n\n")]
    public static void TheTextIsCutByCodePoints(string text, string maxLength, string expected)
    {
        Assert.Equal(expected: expected, actual: DisplayTruncation.Truncate(text: text, maxLength: maxLength));
    }

    [Theory]
    [InlineData("")]
    [InlineData("-1")]
    [InlineData("-0")]
    [InlineData("05")]
    [InlineData("1.5")]
    [InlineData("1e2")]
    [InlineData(" 5")]
    [InlineData("null")]
    [InlineData("1234567890123456")]
    public static void AMaximumLengthJqMightReadDifferentlyIsRefused(string maxLength)
    {
        Assert.Throws<DiscordRefusedException>(() => DisplayTruncation.Truncate(text: "abc", maxLength: maxLength));
    }
}
