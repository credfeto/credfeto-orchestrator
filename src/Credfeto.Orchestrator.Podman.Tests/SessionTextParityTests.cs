using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// Every fixture case, in each of its locales, the message sent as lib/podman sends it (a here-string): the tool must
// return and print what the shell function did, or refuse the cases marked "refuses". A "not-called" case is one bash
// answers before asking the tool, so the tool's answer to it is not checked.
public sealed class SessionTextParityTests : TestBase
{
    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return SessionTextParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheHeuristicMatchesTheShellFunctionAsync(int index, string name)
    {
        SessionTextParityCase parity = await SessionTextParityFixture.CaseAsync(
            index: index,
            cancellationToken: this.CancellationToken()
        );

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "not-called"))
        {
            return;
        }

        byte[] input = [.. PrintfEscapes.Decode(parity.Text), (byte)'\n'];

        foreach (string locale in parity.Locales)
        {
            PodmanTextCommand command = Command(parity: parity, locale: locale);

            if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
            {
                Assert.Throws<PodmanRefusedException>(() => ClaudeTextQueries.Answer(command: command, input: input));

                continue;
            }

            PodmanResult result = ClaudeTextQueries.Answer(command: command, input: input);

            Assert.Equal(
                expected: Describe(
                    name: name,
                    locale: locale,
                    status: parity.Status,
                    stdout: PrintfEscapes.Decode(parity.Stdout)
                ),
                actual: Describe(name: name, locale: locale, status: result.ExitCode, stdout: result.Output.Span)
            );
        }
    }

    private static PodmanTextCommand Command(SessionTextParityCase parity, string locale)
    {
        List<string> args = ["podman", parity.Query, "--ctype", locale, "--collate", locale, .. parity.Arguments];

        return PodmanTextCommandParser.Parse(args: args, error: out string error)
            ?? throw new InvalidOperationException("The fixture's arguments do not parse: " + error);
    }

    private static string Describe(string name, string locale, int status, ReadOnlySpan<byte> stdout)
    {
        string code = status.ToString(CultureInfo.InvariantCulture);

        return $"{name} in {locale}: status {code}, printed {Convert.ToHexString(stdout)}";
    }
}
