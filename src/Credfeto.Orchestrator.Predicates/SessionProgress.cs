using System;

namespace Credfeto.Orchestrator.Predicates;

// pr_session_progress_reason (lib/github-status): what a pull request session changed, judged from the board
// status, latest trusted comment time and head commit read before and after it
public static class SessionProgress
{
    private const string UNKNOWN = "Unknown";

    // The board moving (neither side empty or Unknown) comes first, then a trusted comment newer than the one before
    // (bash's [[ post > pre ]]), then a new head commit. Holds false, printing nothing, when none changed. Refused
    // where the comment times are compared and the caller's locale could order them differently
    public static ChecksAnswer Reason(
        string preBoard,
        string postBoard,
        string preCommentTimestamp,
        string postCommentTimestamp,
        string preHead,
        string postHead
    )
    {
        if (
            preBoard.Length > 0
            && postBoard.Length > 0
            && !StringComparer.Ordinal.Equals(x: preBoard, y: UNKNOWN)
            && !StringComparer.Ordinal.Equals(x: postBoard, y: UNKNOWN)
            && !StringComparer.Ordinal.Equals(x: preBoard, y: postBoard)
        )
        {
            return ChecksAnswer.Printing("board moved from " + preBoard + " to " + postBoard);
        }

        if (postCommentTimestamp.Length > 0)
        {
            bool? newer = SortsAfter(left: postCommentTimestamp, right: preCommentTimestamp);

            if (newer is null)
            {
                return ChecksAnswer.Refused(
                    "the comment times are not two timestamps of the same shape, so the locale could order them"
                );
            }

            if (newer.Value)
            {
                return ChecksAnswer.Printing(
                    "a trusted comment arrived during the session and is left unaddressed for the next run"
                );
            }
        }

        return preHead.Length > 0 && postHead.Length > 0 && !StringComparer.Ordinal.Equals(x: preHead, y: postHead)
            ? ChecksAnswer.Printing("a commit was pushed")
            : ChecksAnswer.Of(holds: false);
    }

    // bash's [[ left > right ]], which orders the two by the locale's collation (strcoll), where every locale the
    // orchestrator runs in (C, C.UTF-8, en_GB.UTF-8) orders them as their bytes do; null where one might not. Equal
    // texts never sort after each other, a printable ASCII text holding a letter or digit sorts after an empty one,
    // and two printable ASCII texts of one length whose first difference is two digits (as between two ISO 8601
    // times) sort by those digits. Anything else (a first difference in letters, which en_GB.UTF-8 orders without
    // regard to case first, or in punctuation, non-ASCII, or texts of two lengths) could be ordered otherwise
    public static bool? SortsAfter(string left, string right)
    {
        if (StringComparer.Ordinal.Equals(x: left, y: right))
        {
            return false;
        }

        if (right.Length == 0)
        {
            return IsPrintableAscii(left) && ContainsAsciiLetterOrDigit(left) ? true : null;
        }

        if (left.Length != right.Length || !IsPrintableAscii(left) || !IsPrintableAscii(right))
        {
            return null;
        }

        int index = 0;

        while (left[index] == right[index])
        {
            ++index;
        }

        return char.IsAsciiDigit(left[index]) && char.IsAsciiDigit(right[index]) ? left[index] > right[index] : null;
    }

    private static bool IsPrintableAscii(string text)
    {
        return !text.AsSpan().ContainsAnyExceptInRange(lowInclusive: '!', highInclusive: '~');
    }

    private static bool ContainsAsciiLetterOrDigit(string text)
    {
        return text.AsSpan().ContainsAnyInRange(lowInclusive: '0', highInclusive: '9')
            || text.AsSpan().ContainsAnyInRange(lowInclusive: 'a', highInclusive: 'z')
            || text.AsSpan().ContainsAnyInRange(lowInclusive: 'A', highInclusive: 'Z');
    }
}
