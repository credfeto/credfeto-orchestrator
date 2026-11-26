using System.Text;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class PkillPatternTests : TestBase
{
    [Theory]
    [InlineData("/run/a.sock", "ssh-agent -a /run/a.sock", PkillMatch.MATCH)]
    [InlineData("/run/a.sock", "/usr/bin/ssh-agent -a /run/a.sock -D", PkillMatch.MATCH)]
    [InlineData("/run/a.sock", "ssh-agent -a /run/aXsock", PkillMatch.MATCH)]
    [InlineData("/run/a.", "ssh-agent -a /run/a ", PkillMatch.MATCH)]
    [InlineData("/run/a.", "ssh-agent -a /run/a", PkillMatch.NO_MATCH)]
    [InlineData("/run/a.sock", "ssh-agent -a /run/a", PkillMatch.NO_MATCH)]
    [InlineData("/run/a.sock", "ssh-agent  -a /run/a.sock", PkillMatch.NO_MATCH)]
    [InlineData("/run/a.sock", "SSH-AGENT -a /run/a.sock", PkillMatch.NO_MATCH)]
    [InlineData("/run/a.sock", "", PkillMatch.NO_MATCH)]
    [InlineData("/run/a.sock", "sssh-agent -a /run/a.sock", PkillMatch.MATCH)]
    [InlineData("/run/a.sock", "ssh-agent -a /run/a\u0001sock", PkillMatch.UNCERTAIN)]
    [InlineData("/run/a.sock", "ssh-agent\n-a /run/a.sock", PkillMatch.UNCERTAIN)]
    [InlineData("/run/a.sock", "ssh-agent -a /run/\u0001.sock", PkillMatch.NO_MATCH)]
    [InlineData("/run/a.sock", "\u0001ssh-agent -a /run/a.sockÿ", PkillMatch.MATCH)]
    [InlineData("/run/a.sock", "ssh-agent\n-a /run/a.sock ssh-agent -a /run/a.sock", PkillMatch.MATCH)]
    [InlineData("/run/my agent", "ssh-agent -a /run/my agent", PkillMatch.MATCH)]
    public static void ThePatternMatchesAsProcpsDoes(string socket, string text, PkillMatch expected)
    {
        PkillPattern pattern = PkillPattern.ForSocket(socket);

        Assert.Equal(expected: expected, actual: pattern.Match(Encoding.Latin1.GetBytes(text)));
    }

    [Theory]
    [InlineData(4077, PkillMatch.MATCH)]
    [InlineData(4078, PkillMatch.UNCERTAIN)]
    [InlineData(5000, PkillMatch.UNCERTAIN)]
    public static void AMatchPastByte4095IsUncertain(int padding, PkillMatch expected)
    {
        PkillPattern pattern = PkillPattern.ForSocket("/a.so");
        string text = new string(c: 'A', count: padding) + "ssh-agent -a /a.so";

        Assert.Equal(expected: expected, actual: pattern.Match(Encoding.ASCII.GetBytes(text)));
    }

    [Fact]
    public static void AMismatchPastByte4095IsCertain()
    {
        PkillPattern pattern = PkillPattern.ForSocket("/a.so");
        string text = new string(c: 'A', count: 4090) + "ssh-agent -a /b.so";

        Assert.Equal(expected: PkillMatch.NO_MATCH, actual: pattern.Match(Encoding.ASCII.GetBytes(text)));
    }

    [Theory]
    [InlineData("")]
    [InlineData("/run/a+b")]
    [InlineData("/run/a*")]
    [InlineData("/run/a?")]
    [InlineData("/run/(a)")]
    [InlineData("/run/[a]")]
    [InlineData("/run/{a}")]
    [InlineData("/run/a|b")]
    [InlineData("/run/^a")]
    [InlineData("/run/a$")]
    [InlineData("/run/a\\.sock")]
    [InlineData("/run/é")]
    [InlineData("/run/a\tb")]
    [InlineData("/run/�")]
    public static void ASocketPathItCannotMatchLiterallyIsRefused(string socket)
    {
        Assert.Throws<AgentRefusedException>(() => PkillPattern.ForSocket(socket));
    }
}
