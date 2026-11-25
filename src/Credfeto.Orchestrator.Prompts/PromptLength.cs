using System;
using System.Linq;

namespace Credfeto.Orchestrator.Prompts;

// ${#prompt} in bash, for the MAX_PROMPT_CHARS guard (invoke_claude, lib/podman): in a UTF-8 locale bash counts
// characters as glibc's mbrlen reads them, and every byte that does not start a valid sequence as one character; in
// any other locale it counts bytes
public static class PromptLength
{
    private const byte CONTINUATION_MASK = 0xC0;
    private const byte CONTINUATION = 0x80;

    private static readonly string[] LocaleVariables = ["LC_ALL", "LC_CTYPE", "LANG"];

    public static int Count(ReadOnlySpan<byte> text, bool utf8)
    {
        if (!utf8)
        {
            return text.Length;
        }

        int count = 0;
        int index = 0;

        while (index < text.Length)
        {
            index += SequenceLength(text[index..]);
            count++;
        }

        return count;
    }

    // Whether bash runs in a UTF-8 locale: the first of LC_ALL, LC_CTYPE and LANG that is set names its codeset
    public static bool IsUtf8Locale(Func<string, string?> environment)
    {
        string? locale = LocaleVariables.Select(environment).FirstOrDefault(value => !string.IsNullOrEmpty(value));

        return locale is not null && IsUtf8Codeset(locale);
    }

    private static bool IsUtf8Codeset(string locale)
    {
        int dot = locale.IndexOf('.', StringComparison.Ordinal);

        if (dot < 0)
        {
            return false;
        }

        string codeset = locale[(dot + 1)..];
        int modifier = codeset.IndexOf('@', StringComparison.Ordinal);

        if (modifier >= 0)
        {
            codeset = codeset[..modifier];
        }

        return StringComparer.OrdinalIgnoreCase.Equals(x: codeset, y: "UTF-8")
            || StringComparer.OrdinalIgnoreCase.Equals(x: codeset, y: "utf8");
    }

    // glibc's UTF-8 decoder: up to six bytes (so above U+10FFFF too), no overlong forms and no surrogates
    private static int SequenceLength(ReadOnlySpan<byte> text)
    {
        byte lead = text[0];
        int length = LeadLength(lead);

        if (length <= 1 || length > text.Length)
        {
            return 1;
        }

        long value = lead & (0x7F >> length);

        for (int index = 1; index < length; index++)
        {
            if ((text[index] & CONTINUATION_MASK) != CONTINUATION)
            {
                return 1;
            }

            value = (value << 6) | (uint)(text[index] & 0x3F);
        }

        return IsValid(value: value, length: length) ? length : 1;
    }

    private static int LeadLength(byte lead)
    {
        return lead switch
        {
            < 0x80 => 1,
            >= 0xC2 and <= 0xDF => 2,
            >= 0xE0 and <= 0xEF => 3,
            >= 0xF0 and <= 0xF7 => 4,
            >= 0xF8 and <= 0xFB => 5,
            >= 0xFC and <= 0xFD => 6,
            _ => 0,
        };
    }

    private static bool IsValid(long value, int length)
    {
        long minimum = length switch
        {
            2 => 0x80,
            3 => 0x800,
            4 => 0x10000,
            5 => 0x200000,
            _ => 0x4000000,
        };

        return value >= minimum && value is not (>= 0xD800 and <= 0xDFFF);
    }
}
