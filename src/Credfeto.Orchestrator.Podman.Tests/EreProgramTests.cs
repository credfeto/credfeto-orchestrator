using System;
using System.Text;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

public sealed class EreProgramTests : TestBase
{
    [Theory]
    [InlineData("(pushed|pushed yet)", "not pushed yet.", "pushed yet")]
    [InlineData("a|ab|abc", "zabcd", "abc")]
    [InlineData("abcd|bc", "abcd", "abcd")]
    [InlineData("bc|abcd", "xabcd", "abcd")]
    [InlineData("(a|ab)(c|bcd)(d*)", "abcd", "abcd")]
    [InlineData("x*", "abc", "")]
    [InlineData("(^|[^a-z])no( [a-z]+){0,3} pushed", "no x pushed y pushed z pushed", "no x pushed y pushed")]
    [InlineData(
        "([a-z]n[^a-z ]{1,3}t|(^|[^a-z])(not|no))( yet)? pushed|(^|[^a-z])no( [a-z]+){0,3} (was|were) pushed",
        "so no pushed were pushed",
        " no pushed were pushed"
    )]
    [InlineData("don[^a-z ]{1,3}t", "DON'''T", "DON'''T")]
    [InlineData("n.t", "n\nt", "n\nt")]
    [InlineData("pushed$", "pushed. pushed", "pushed")]
    [InlineData("a{2,}", "aaaa", "aaaa")]
    [InlineData("[]n]ot", "]ot", "]ot")]
    [InlineData("[n-]ot", "-ot", "-ot")]
    [InlineData("a\\.b", "a.b", "a.b")]
    public static void TheMatchIsLeftmostThenLongest(string pattern, string text, string expected)
    {
        (int Start, int Length)? match = EreProgram.Compile(pattern).FindLeftmostLongest(Encoding.ASCII.GetBytes(text));

        Assert.NotNull(match);
        Assert.Equal(
            expected: expected,
            actual: text.Substring(startIndex: match.Value.Start, length: match.Value.Length)
        );
    }

    [Theory]
    [InlineData("Bash is denied", "BASH IS DENIED", true)]
    [InlineData("[^a-z ]", "X", false)]
    [InlineData("[a-z]", "Q", true)]
    [InlineData("don[^a-z ]{1,3}t", "DONXT", false)]
    [InlineData("I.ll", "Ill", false)]
    [InlineData("^bash", "the bash", false)]
    [InlineData("^bash|the", "the bash", true)]
    [InlineData("x^a", "x^a", false)]
    [InlineData("a$b", "a$b", false)]
    [InlineData("[0-9]", "five", false)]
    [InlineData("[1-9][0-9]*", "10", true)]
    [InlineData("a{0,0}b", "b", true)]
    public static void IsMatchFoldsCaseAndAnchorsAtTheTextEnds(string pattern, string text, bool expected)
    {
        Assert.Equal(expected: expected, actual: EreProgram.Compile(pattern).IsMatch(Encoding.ASCII.GetBytes(text)));
    }

    [Theory]
    [InlineData("[^a-z ]")]
    [InlineData(".")]
    [InlineData("[^.]")]
    public static void AByteOf0x80OrMoreMatchesOnlyDotAndNegatedLists(string pattern)
    {
        Assert.True(condition: EreProgram.Compile(pattern).IsMatch([0xE2]), userMessage: pattern);
        Assert.False(condition: EreProgram.Compile("[a-z]|[0-9]|e").IsMatch([0xE9]), userMessage: pattern);
    }

    [Fact]
    public static void NoMatchIsNull()
    {
        Assert.Null(EreProgram.Compile("pushed").FindLeftmostLongest("nothing"u8));
    }

    [Theory]
    [InlineData("")]
    [InlineData("\\w")]
    [InlineData("\\bnot")]
    [InlineData("(a)\\1")]
    [InlineData("[[:alpha:]]")]
    [InlineData("[A-Z]")]
    [InlineData("[aB]")]
    [InlineData("[\\.]")]
    [InlineData("[a-z-9]")]
    [InlineData("[z-a]")]
    [InlineData("[!-~]")]
    [InlineData("[abc")]
    [InlineData("a{2")]
    [InlineData("a{,3}")]
    [InlineData("a{256}")]
    [InlineData("a{3,2}")]
    [InlineData("a{1}{2}")]
    [InlineData("a**")]
    [InlineData("a+?")]
    [InlineData("*a")]
    [InlineData("(*a)")]
    [InlineData("^*")]
    [InlineData("(a")]
    [InlineData("a)")]
    [InlineData("()")]
    [InlineData("a||b")]
    [InlineData("a|")]
    [InlineData("a}")]
    [InlineData("a]")]
    [InlineData("caf\u00E9")]
    [InlineData("a\tb")]
    public static void APatternOutsideTheSubsetIsRefused(string pattern)
    {
        Assert.Throws<PodmanRefusedException>(() => EreProgram.Compile(pattern));
    }

    [Fact]
    public static void APatternThatExpandsTooFarIsRefused()
    {
        Assert.Throws<PodmanRefusedException>(() => EreProgram.Compile("((((a{255}){255}){255}){255})"));
    }

    [Fact]
    public static void ALongTextIsMatchedInOnePass()
    {
        byte[] text = new byte[200_000];
        Array.Fill(array: text, value: (byte)'a');
        text[^1] = (byte)'b';

        Assert.Equal(expected: (0, text.Length), actual: EreProgram.Compile("a*b").FindLeftmostLongest(text));
    }
}
