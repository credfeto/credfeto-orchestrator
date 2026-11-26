using System.Text;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class PkillTextTests : TestBase
{
    [Theory]
    [InlineData("ssh-agent\0-a\0/run/a.sock\0", "", "ssh-agent -a /run/a.sock")]
    [InlineData("ssh-agent\0-a\0\0", "", "ssh-agent -a ")]
    [InlineData("no trailing nul", "", "no trailing nul")]
    [InlineData("a\0", "", "a")]
    [InlineData("\0", "", "")]
    [InlineData("", "ssh-agent", "[ssh-agent]")]
    [InlineData("", "", "[]")]
    public static void TheCommandLineIsJoinedAsProcpsJoinsIt(string commandLine, string name, string expected)
    {
        byte[] text = PkillText.FromProcess(
            commandLine: Encoding.Latin1.GetBytes(commandLine),
            name: Encoding.Latin1.GetBytes(name)
        );

        Assert.Equal(expected: expected, actual: Encoding.Latin1.GetString(text));
    }
}
