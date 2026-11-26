using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class SessionStalledPayloadTests : TestBase
{
    [Theory]
    [InlineData("token ghp_AbC123_x here", "token [token] here")]
    [InlineData("gho_a ghu_b ghs_c ghr_d", "[token] [token] [token] [token]")]
    [InlineData("github_pat_11AB_cd and github_pat_", "[token] and github_pat_")]
    [InlineData("ghp_ alone, ghx_abc, GHP_abc", "ghp_ alone, ghx_abc, GHP_abc")]
    [InlineData("xghp_abc-def", "x[token]-def")]
    [InlineData("sha 0123456789abcdef0123456789abcde end", "sha 0123456789abcdef0123456789abcde end")]
    [InlineData("sha 0123456789abcdef0123456789ABCDEF end", "sha [token] end")]
    [InlineData("file /home/x/y.txt and https://example.com/a.", "file [path] and [path]")]
    [InlineData("a / b // c", "a [path] b [path] c")]
    [InlineData("ghp_ab/cd", "[path]")]
    [InlineData("k ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ end", "k ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ end")]
    [InlineData("k ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ end", "k [token] end")]
    [InlineData("k AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA end", "k [token] end")]
    [InlineData("k Az09+=_-Az09+=_-Az09+=_-Az09+=_-Az09+=_- end", "k [token] end")]
    [InlineData(
        "k ZZZZZZZZZZZZZZZZZZZZ\u00e9ZZZZZZZZZZZZZZZZZZZZ end",
        "k ZZZZZZZZZZZZZZZZZZZZ\u00e9ZZZZZZZZZZZZZZZZZZZZ end"
    )]
    public static void TheMessageIsMaskedAsJqMasksIt(string message, string expected)
    {
        Assert.Equal(expected: expected, actual: SessionStalledPayload.Mask(message));
    }

    [Theory]
    [InlineData("\t")]
    [InlineData("\n")]
    [InlineData("\v")]
    [InlineData("\f")]
    [InlineData("\r")]
    [InlineData(" ")]
    [InlineData("\u0085")]
    [InlineData("\u00a0")]
    [InlineData("\u1680")]
    [InlineData("\u2000")]
    [InlineData("\u200a")]
    [InlineData("\u2028")]
    [InlineData("\u2029")]
    [InlineData("\u202f")]
    [InlineData("\u205f")]
    [InlineData("\u3000")]
    public static void OnigurumaWhiteSpaceEndsAPath(string space)
    {
        Assert.Equal(
            expected: $"left{space}[path]{space}right",
            actual: SessionStalledPayload.Mask($"left{space}a/b{space}right")
        );
    }

    [Theory]
    [InlineData("\u001c")]
    [InlineData("\u001f")]
    [InlineData("\u00ad")]
    [InlineData("\u180e")]
    [InlineData("\u200b")]
    [InlineData("\u200d")]
    [InlineData("\u2060")]
    [InlineData("\ufeff")]
    public static void OtherInvisibleCharactersArePartOfAPath(string character)
    {
        Assert.Equal(expected: "[path]", actual: SessionStalledPayload.Mask($"left{character}a/b{character}right"));
    }
}
