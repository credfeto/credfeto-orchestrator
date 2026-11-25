using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace Credfeto.Orchestrator.State.Tests;

// Decodes the printf %b text test/fixtures/state-parity.json holds its arguments and outputs in. Only the escapes the
// fixture uses are taken (\\, \n, \r, \t and \xHH); any other backslash fails, so a fixture escape bash would read
// differently cannot pass unnoticed
internal static class PrintfEscapes
{
    public static byte[] Decode(string text)
    {
        using MemoryStream bytes = new();
        int index = 0;

        while (index < text.Length)
        {
            char current = text[index];

            if (current != '\\')
            {
                int length = char.IsHighSurrogate(current) ? 2 : 1;
                bytes.Write(Encoding.UTF8.GetBytes(text.Substring(startIndex: index, length: length)));
                index += length;

                continue;
            }

            index += DecodeEscape(text: text, index: index, bytes: bytes);
        }

        return bytes.ToArray();
    }

    private static int DecodeEscape(string text, int index, MemoryStream bytes)
    {
        char escape = index + 1 < text.Length ? text[index + 1] : '\0';

        switch (escape)
        {
            case '\\':
                bytes.WriteByte((byte)'\\');

                return 2;
            case 'n':
                bytes.WriteByte((byte)'\n');

                return 2;
            case 'r':
                bytes.WriteByte((byte)'\r');

                return 2;
            case 't':
                bytes.WriteByte((byte)'\t');

                return 2;
            case 'x' when index + 3 < text.Length:
                bytes.WriteByte(
                    byte.Parse(
                        s: text.AsSpan(start: index + 2, length: 2),
                        style: NumberStyles.AllowHexSpecifier,
                        provider: CultureInfo.InvariantCulture
                    )
                );

                return 4;
            default:
                throw new FormatException(
                    "Unsupported printf %b escape at " + index.ToString(CultureInfo.InvariantCulture)
                );
        }
    }
}
