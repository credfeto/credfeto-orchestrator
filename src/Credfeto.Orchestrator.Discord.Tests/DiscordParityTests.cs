using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

// Every fixture case, built through the discord command line from the same values: the payload must be the text the
// shell function printed, or the cases marked "refuses" refused
public sealed class DiscordParityTests : TestBase
{
    // How the runtime reads an argument on Linux: UTF-8, every invalid sequence replaced with U+FFFD
    private static readonly Encoding Arguments = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return DiscordParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task ThePayloadMatchesTheShellFunctionAsync(int index, string name)
    {
        CancellationToken cancellationToken = this.CancellationToken();
        DiscordParityCase parity = await DiscordParityFixture.CaseAsync(
            index: index,
            cancellationToken: cancellationToken
        );

        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using StringWriter output = new(CultureInfo.InvariantCulture);
        int status = await DiscordCommandRunner.RunAsync(
            args: CommandLine(parity),
            output: output,
            error: error,
            cancellationToken: cancellationToken
        );

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
        {
            Assert.Equal(expected: $"{name}: {DiscordCommandRunner.Refused}", actual: $"{name}: {status}");

            return;
        }

        Assert.Equal(expected: $"{name}: {parity.Status}", actual: $"{name}: {status}");
        Assert.Equal(expected: parity.Stdout, actual: output.ToString());
        Assert.Equal(expected: string.Empty, actual: error.ToString());
    }

    private static List<string> CommandLine(DiscordParityCase parity)
    {
        Assert.Equal(expected: parity.Options.Count, actual: parity.Arguments.Count);
        List<string> args = [DiscordCommandParser.Verb, DiscordCommandParser.Payload, parity.Kind];

        for (int index = 0; index < parity.Options.Count; index++)
        {
            args.Add("--" + parity.Options[index]);
            args.Add(Arguments.GetString(PrintfEscapes.Decode(parity.Arguments[index])));
        }

        return args;
    }
}
