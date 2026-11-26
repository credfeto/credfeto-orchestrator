using System;
using System.Collections.Generic;
using System.Globalization;

namespace Credfeto.Orchestrator.Agents.Tests;

// Decodes the printf %b text the stop parity fixture writes its bytes in: \\, \n, \t and \xHH, everything else as is
internal static class PrintfText
{
    public static byte[] Decode(string text)
    {
        List<byte> bytes = [];
        ReadOnlySpan<char> rest = text;

        while (!rest.IsEmpty)
        {
            if (rest[0] != '\\')
            {
                bytes.Add(checked((byte)rest[0]));
                rest = rest[1..];

                continue;
            }

            int length = DecodeEscape(escape: rest[1..], bytes: bytes);
            rest = rest[(1 + length)..];
        }

        return [.. bytes];
    }

    // Adds the byte the escape after a backslash stands for, and returns how many characters it took
    private static int DecodeEscape(ReadOnlySpan<char> escape, List<byte> bytes)
    {
        switch (escape[0])
        {
            case '\\':
                bytes.Add((byte)'\\');

                return 1;
            case 'n':
                bytes.Add((byte)'\n');

                return 1;
            case 't':
                bytes.Add((byte)'\t');

                return 1;
            case 'x':
                bytes.Add(
                    byte.Parse(s: escape[1..3], style: NumberStyles.HexNumber, provider: CultureInfo.InvariantCulture)
                );

                return 3;
            default:
                throw new FormatException("Unexpected escape \\" + escape[0]);
        }
    }
}
