using System;
using System.Globalization;
using System.Text;

namespace Credfeto.Orchestrator.Discord;

// lib/discord's truncate_for_display: jq -Rsr cuts the text to max_len code points and appends the notice when it
// cut anything, then prints its newline
public static class DisplayTruncation
{
    public const string Notice = "\n... (truncated; see the run log for the full list)";

    public static string Truncate(string text, string maxLength)
    {
        long limit = MaximumLength(maxLength);
        int length = 0;
        int index = 0;

        foreach (Rune rune in text.EnumerateRunes())
        {
            if (length == limit)
            {
                return text[..index] + Notice + "\n";
            }

            length++;
            index += rune.Utf16SequenceLength;
        }

        return text + "\n";
    }

    // The --argjson max_len: only a plain non-negative JSON integer, which jq reads as written; jq fails on some
    // other texts and reads the rest in its own way, so bash handles them
    private static long MaximumLength(string maxLength)
    {
        if (maxLength.Length == 0 || maxLength[0] == '-' || !DiscordTextInput.IsPlainInteger(maxLength))
        {
            throw new DiscordRefusedException($"--max-length {maxLength} is not a plain non-negative JSON integer");
        }

        return long.Parse(s: maxLength, style: NumberStyles.None, provider: CultureInfo.InvariantCulture);
    }
}
