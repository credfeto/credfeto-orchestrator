using System;

namespace Credfeto.Orchestrator.State;

// The byte-level rules the lib/state reads follow
public static class StateText
{
    private const byte NEWLINE = (byte)'\n';
    private const byte FIRST_NON_ASCII = 0x80;

    // $(cat file): the trailing newlines go
    public static ReadOnlySpan<byte> CommandSubstitution(ReadOnlySpan<byte> content)
    {
        int length = content.Length;

        while (length > 0 && content[length - 1] == NEWLINE)
        {
            length--;
        }

        return content[..length];
    }

    // bash drops a NUL byte from $(...) and read with a warning of its own, so the tool leaves such a file to bash
    public static void RefuseNul(ReadOnlySpan<byte> content, string path)
    {
        if (content.Contains((byte)0))
        {
            throw new StateRefusedException("NUL byte in " + path);
        }
    }

    // [[ =~ ^[0-9]+$ ]] and grep take a non-ASCII byte by the locale's rules, so the tool leaves such a file to bash
    public static void RefuseNonAscii(ReadOnlySpan<byte> content, string path)
    {
        RefuseNul(content: content, path: path);

        if (content.ContainsAnyInRange(lowInclusive: FIRST_NON_ASCII, highInclusive: byte.MaxValue))
        {
            throw new StateRefusedException("non-ASCII byte in " + path);
        }
    }

    // ^[0-9]+$ over the whole text
    public static bool IsDigits(ReadOnlySpan<byte> text)
    {
        return !text.IsEmpty && !text.ContainsAnyExceptInRange(lowInclusive: (byte)'0', highInclusive: (byte)'9');
    }

    public static bool IsDigits(ReadOnlySpan<char> text)
    {
        return !text.IsEmpty && !text.ContainsAnyExceptInRange(lowInclusive: '0', highInclusive: '9');
    }
}
