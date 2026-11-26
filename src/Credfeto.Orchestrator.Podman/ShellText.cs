using System;

namespace Credfeto.Orchestrator.Podman;

// The few shell operations on a message the heuristics use, on the text the tool accepts (ASCII in any accepted
// locale, any byte but NUL in the C locale), where bash works byte by byte: ${text,,} lower-cases A to Z only, and
// [[:space:]] is tab, newline, vertical tab, form feed, carriage return and space (probed with bash 5.3 in C,
// C.UTF-8 and en_GB.UTF-8, and for 0x80 to 0xFF in C).
internal static class ShellText
{
    public static byte ToLowerAscii(byte value)
    {
        return value is >= (byte)'A' and <= (byte)'Z' ? (byte)(value + ('a' - 'A')) : value;
    }

    public static byte[] ToLowerAscii(ReadOnlySpan<byte> text)
    {
        byte[] lowered = new byte[text.Length];

        for (int index = 0; index < text.Length; index++)
        {
            lowered[index] = ToLowerAscii(text[index]);
        }

        return lowered;
    }

    public static bool IsSpace(byte value)
    {
        return value is (byte)' ' or >= (byte)'\t' and <= (byte)'\r';
    }

    public static ReadOnlySpan<byte> Trim(ReadOnlySpan<byte> text)
    {
        int start = 0;

        while (start < text.Length && IsSpace(text[start]))
        {
            start++;
        }

        int end = text.Length;

        while (end > start && IsSpace(text[end - 1]))
        {
            end--;
        }

        return text[start..end];
    }
}
