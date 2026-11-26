using System;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

// Every fixture case's stand-in command line ("<argv0> 30", as exec -a <argv0> sleep 30 makes it), read as the proc
// table reads it and matched against the case's pattern: the tool must kill exactly the stand-ins pkill killed, or
// refuse the cases marked "refuses"
public sealed class AgentStopParityTests : TestBase
{
    private const string ROOT = "/tmp/orchestrator-stop-parity/root";

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return AgentStopParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheMatchIsPkillsAsync(int index, string name)
    {
        Assert.NotEmpty(name);
        AgentStopParityCase parity = await AgentStopParityFixture.CaseAsync(
            index: index,
            cancellationToken: this.CancellationToken()
        );
        string socket = Encoding.Latin1.GetString(Bytes(parity.Socket));
        byte[] argv0 = Bytes(parity.Argv0);
        byte[] commandLine = [.. argv0, 0, (byte)'3', (byte)'0', 0];

        PkillMatch match = Match(socket: socket, text: PkillText.FromProcess(commandLine: commandLine, name: []));

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
        {
            Assert.Equal(expected: PkillMatch.UNCERTAIN, actual: match);

            return;
        }

        Assert.Equal(expected: parity.Killed == true ? PkillMatch.MATCH : PkillMatch.NO_MATCH, actual: match);
    }

    private static byte[] Bytes(string text)
    {
        return PrintfText.Decode(
            text.Replace(oldValue: "@ROOT@", newValue: ROOT, comparisonType: StringComparison.Ordinal)
        );
    }

    // A socket path the pattern refuses counts as UNCERTAIN, as the tool refuses it the same way
    private static PkillMatch Match(string socket, byte[] text)
    {
        try
        {
            return PkillPattern.ForSocket(socket).Match(text);
        }
        catch (AgentRefusedException)
        {
            return PkillMatch.UNCERTAIN;
        }
    }
}
