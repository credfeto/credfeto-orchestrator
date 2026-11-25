using System;

namespace Credfeto.Orchestrator.Git;

// issue_branch_regex's ^[A-Za-z]+/<issue>([^0-9]|$), matched over a branch name's bytes as bash matches it. Bash
// matches in the caller's locale, which decides whether a non-ASCII character is a letter (en_GB takes é) or a digit
// (en_GB takes ²); every locale agrees on ASCII. So the answer is MATCH or NO_MATCH only when the ASCII characters
// decide it, and LOCALE_DEPENDENT otherwise.
public static class IssueBranchPattern
{
    public static bool IsIssueNumber(string issue)
    {
        return issue.Length > 0 && !issue.AsSpan().ContainsAnyExceptInRange(lowInclusive: '0', highInclusive: '9');
    }

    public static StaleBranchMatch Match(ReadOnlySpan<byte> branch, ReadOnlySpan<byte> issue)
    {
        int slash = branch.IndexOf((byte)'/');

        if (slash <= 0)
        {
            return StaleBranchMatch.NO_MATCH;
        }

        ReadOnlySpan<byte> type = branch[..slash];

        if (HasAsciiNonLetter(type))
        {
            // No locale takes an ASCII character other than a letter for one, and [A-Za-z]+ cannot step over the slash
            return StaleBranchMatch.NO_MATCH;
        }

        ReadOnlySpan<byte> rest = branch[(slash + 1)..];

        if (!rest.StartsWith(issue))
        {
            return StaleBranchMatch.NO_MATCH;
        }

        StaleBranchMatch after = AfterNumber(rest[issue.Length..]);

        return after == StaleBranchMatch.MATCH && !IsAscii(type) ? StaleBranchMatch.LOCALE_DEPENDENT : after;
    }

    // ([^0-9]|$) on what follows the number
    private static StaleBranchMatch AfterNumber(ReadOnlySpan<byte> after)
    {
        if (after.IsEmpty)
        {
            return StaleBranchMatch.MATCH;
        }

        byte next = after[0];

        if (next >= 0x80)
        {
            return StaleBranchMatch.LOCALE_DEPENDENT;
        }

        return char.IsAsciiDigit((char)next) ? StaleBranchMatch.NO_MATCH : StaleBranchMatch.MATCH;
    }

    private static bool HasAsciiNonLetter(ReadOnlySpan<byte> text)
    {
        foreach (byte value in text)
        {
            if (value < 0x80 && !char.IsAsciiLetter((char)value))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsAscii(ReadOnlySpan<byte> text)
    {
        return !text.ContainsAnyInRange(lowInclusive: (byte)0x80, highInclusive: (byte)0xFF);
    }
}
