using System;
using System.Globalization;
using System.Text;

namespace Credfeto.Orchestrator.Jq;

// Decodes a JSON string literal the way jq does when System.Text.Json refuses it for an unpaired
// surrogate escape: a lone low surrogate becomes U+FFFD, and a high surrogate that is not followed
// by a low surrogate escape is a parse error.
internal static class JqStringDecoder
{
    private const int ESCAPE_DIGITS = 4;
    private const char REPLACEMENT = '�';

    public static string Decode(string literal)
    {
        // literal includes its surrounding quotes
        StringBuilder builder = new(literal.Length);
        int index = 1;
        int end = literal.Length - 1;

        while (index < end)
        {
            char character = literal[index];

            if (character != '\\')
            {
                builder.Append(character);
                index++;

                continue;
            }

            index = AppendEscape(builder: builder, literal: literal, index: index);
        }

        return builder.ToString();
    }

    private static int AppendEscape(StringBuilder builder, string literal, int index)
    {
        char escape = literal[index + 1];

        if (escape != 'u')
        {
            builder.Append(Unescape(escape));

            return index + 2;
        }

        char unit = ReadUnit(literal: literal, index: index);

        if (char.IsLowSurrogate(unit))
        {
            builder.Append(REPLACEMENT);

            return index + 2 + ESCAPE_DIGITS;
        }

        if (!char.IsHighSurrogate(unit))
        {
            builder.Append(unit);

            return index + 2 + ESCAPE_DIGITS;
        }

        int next = index + 2 + ESCAPE_DIGITS;

        if (next + 1 < literal.Length && literal[next] == '\\' && literal[next + 1] == 'u')
        {
            char low = ReadUnit(literal: literal, index: next);

            if (char.IsLowSurrogate(low))
            {
                builder.Append(unit).Append(low);

                return next + 2 + ESCAPE_DIGITS;
            }
        }

        throw new JqException("Invalid \\uXXXX\\uXXXX surrogate pair escape");
    }

    private static char ReadUnit(string literal, int index)
    {
        return (char)
            int.Parse(
                s: literal.AsSpan(start: index + 2, length: ESCAPE_DIGITS),
                style: NumberStyles.AllowHexSpecifier,
                provider: CultureInfo.InvariantCulture
            );
    }

    private static char Unescape(char escape)
    {
        return escape switch
        {
            'b' => '\b',
            'f' => '\f',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            _ => escape,
        };
    }
}
