using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

// Every fixture case, run through the discord command line with exactly the arguments and stdin lib/discord's
// _discord_text_from_tool hands the tool for that function: the text must be what the shell function printed, or the
// cases marked "refuses" refused
public sealed class DiscordTextParityTests : TestBase
{
    // How the runtime reads an argument on Linux: UTF-8, every invalid sequence replaced with U+FFFD
    private static readonly Encoding Arguments = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return DiscordTextParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheTextMatchesTheShellFunctionAsync(int index, string name)
    {
        CancellationToken cancellationToken = this.CancellationToken();
        DiscordTextParityCase parity = await DiscordTextParityFixture.CaseAsync(
            index: index,
            cancellationToken: cancellationToken
        );

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "not-called"))
        {
            // serialize_item_status_log with no entries prints [] in bash without asking the tool
            Assert.Equal(expected: $"{name}: []", actual: $"{name}: {parity.Stdout}");

            return;
        }

        (IReadOnlyList<string> args, byte[] input) = Invocation(parity);
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using StringWriter output = new(CultureInfo.InvariantCulture);
        int status = await DiscordCommandRunner.RunAsync(
            args: args,
            input: () => new MemoryStream(input),
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

    // The tool's arguments and stdin for the case, as lib/discord builds them
    private static (IReadOnlyList<string> Args, byte[] Input) Invocation(DiscordTextParityCase parity)
    {
        IReadOnlyList<byte[]> values = [.. parity.Arguments.Select(PrintfEscapes.Decode)];

        return parity.Function switch
        {
            "record_item_status" => (
                [
                    "discord",
                    "item-status",
                    "--type",
                    Argument(values[0]),
                    "--id",
                    Argument(values[1]),
                    "--repo",
                    Argument(values[2]),
                    "--reason",
                    Argument(values[3]),
                ],
                []
            ),
            "serialize_item_status_log" => (["discord", "item-status-log"], HereString(Lines(values))),
            "_build_no_work_item_breakdown" => (
                [
                    "discord",
                    "no-work-breakdown",
                    "--default-repo",
                    Argument(PrintfEscapes.Decode(parity.RepoFull ?? string.Empty)),
                    "--length-unit",
                    StringComparer.Ordinal.Equals(x: parity.Locale, y: "C") ? "bytes" : "characters",
                ],
                HereString(values[0])
            ),
            "truncate_for_display" => (
                ["discord", "truncate", "--max-length", MaxLength(values)],
                HereString(values[0])
            ),
            _ => throw new ArgumentOutOfRangeException(nameof(parity), parity.Function, "Unknown text function"),
        };
    }

    private static string Argument(byte[] value)
    {
        return Arguments.GetString(value);
    }

    // truncate_for_display's "${2:-900}"
    private static string MaxLength(IReadOnlyList<byte[]> values)
    {
        return values.Count > 1 && values[1].Length > 0 ? Argument(values[1]) : "900";
    }

    // printf -v entries '%s\n' "$@"
    private static byte[] Lines(IReadOnlyList<byte[]> values)
    {
        return [.. values.SelectMany(value => value.Append((byte)'\n'))];
    }

    // <<< "${value}": the value and one newline
    private static byte[] HereString(byte[] value)
    {
        return [.. value, (byte)'\n'];
    }
}
