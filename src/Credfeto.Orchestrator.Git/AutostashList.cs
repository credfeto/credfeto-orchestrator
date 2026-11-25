using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Unicode;

namespace Credfeto.Orchestrator.Git;

// autostashes_beyond_keep over what git stash list --format=%gd%x09%gs printed: each line read as bash's
// while IFS=$'\t' read -r ref subject reads it, the subject matched against ^On [^:]*: <prefix> , and the matches
// beyond the newest <keep> given back as "<ref>\t<subject>\n" lines, highest index first
public static class AutostashList
{
    private const byte TAB = (byte)'\t';
    private const byte NEWLINE = (byte)'\n';

    private static readonly byte[] SubjectStart = "On "u8.ToArray();

    // A prefix bash's regex takes literally, whatever the locale: ASCII letters, digits, '-' and '_' (or none)
    public static bool IsPlainPrefix(string prefix)
    {
        return prefix.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_');
    }

    // The keep as [ reads a decimal number, or null for anything else (bash's [ then fails, or reads it otherwise)
    public static long? ParseKeep(string keep)
    {
        if (keep.Length == 0 || keep.AsSpan().ContainsAnyExceptInRange(lowInclusive: '0', highInclusive: '9'))
        {
            return null;
        }

        return long.TryParse(
            s: keep,
            style: NumberStyles.None,
            provider: CultureInfo.InvariantCulture,
            result: out long value
        )
            ? value
            : null;
    }

    // Bash compares the subject's characters in the locale: a list that is not UTF-8 is matched differently in a
    // UTF-8 locale than in C, and a NUL byte is dropped by read, so either is refused
    public static bool IsReadAlike(ReadOnlySpan<byte> list)
    {
        return !list.Contains((byte)0) && Utf8.IsValid(list);
    }

    public static byte[] BeyondKeep(ReadOnlySpan<byte> list, ReadOnlySpan<byte> prefix, long keep)
    {
        byte[] marker = [(byte)' ', .. prefix, (byte)' '];
        List<byte[]> excess = [];
        long seen = 0;
        ReadOnlySpan<byte> rest = list;

        // Only lines ended by a newline: read fails on a last line without one, which ends the loop unread
        for (int end = rest.IndexOf(NEWLINE); end >= 0; end = rest.IndexOf(NEWLINE))
        {
            ReadOnlySpan<byte> line = rest[..end];
            rest = rest[(end + 1)..];
            Split(line: line, reference: out ReadOnlySpan<byte> reference, subject: out ReadOnlySpan<byte> subject);

            if (!IsAutostash(subject: subject, marker: marker))
            {
                continue;
            }

            seen++;

            if (seen > keep)
            {
                excess.Add([.. reference, TAB, .. subject, NEWLINE]);
            }
        }

        List<byte> output = [];

        for (int index = excess.Count - 1; index >= 0; index--)
        {
            output.AddRange(excess[index]);
        }

        return [.. output];
    }

    // IFS=$'\t' read -r ref subject: leading tabs dropped, ref up to the next tab, then the rest with the tabs around
    // it dropped (a tab is IFS white space, so a run of them is one separator)
    private static void Split(ReadOnlySpan<byte> line, out ReadOnlySpan<byte> reference, out ReadOnlySpan<byte> subject)
    {
        ReadOnlySpan<byte> fields = line.TrimStart(TAB);
        int tab = fields.IndexOf(TAB);

        if (tab < 0)
        {
            reference = fields;
            subject = [];

            return;
        }

        reference = fields[..tab];
        subject = fields[tab..].Trim(TAB);
    }

    // ^On [^:]*: <prefix> : [^:]* cannot step over a colon, so the first colon after "On " is the only one that can
    // match, and the prefix with a space each side must follow it
    private static bool IsAutostash(ReadOnlySpan<byte> subject, ReadOnlySpan<byte> marker)
    {
        if (!subject.StartsWith(SubjectStart))
        {
            return false;
        }

        ReadOnlySpan<byte> afterStart = subject[SubjectStart.Length..];
        int colon = afterStart.IndexOf((byte)':');

        return colon >= 0 && afterStart[(colon + 1)..].StartsWith(marker);
    }
}
