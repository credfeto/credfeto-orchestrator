using System;

namespace Credfeto.Orchestrator.Podman;

// The session-outcome text heuristics of lib/podman over a message the tool accepts (see SessionTextLocale), each
// with the patterns lib/podman passes: match_nocase is EreProgram.IsMatch, and the negated-phrase removal is bash's
// loop: lower-case the message (${text,,}), then while the negated pattern matches, replace the first literal
// occurrence of the whole match (BASH_REMATCH[0]) with a space.
internal static class SessionTextHeuristics
{
    // claude_result_indicates_background_stall and claude_result_indicates_diagnostic_refusal (whose 500-character
    // cap stays in bash)
    public static bool Matches(ReadOnlySpan<byte> text, string pattern)
    {
        return EreProgram.Compile(pattern).IsMatch(text);
    }

    // claude_result_indicates_tool_denied_quit
    public static bool ToolDeniedQuit(
        ReadOnlySpan<byte> text,
        string mention,
        string giveUp,
        string workaround,
        string negated
    )
    {
        EreProgram mentionProgram = EreProgram.Compile(mention);
        EreProgram giveUpProgram = EreProgram.Compile(giveUp);
        EreProgram workaroundProgram = EreProgram.Compile(workaround);
        EreProgram negatedProgram = EreProgram.Compile(negated);

        if (!mentionProgram.IsMatch(text) || !giveUpProgram.IsMatch(text))
        {
            return false;
        }

        return !workaroundProgram.IsMatch(WithoutNegated(text: text, negated: negatedProgram));
    }

    // review_result_marker: CLEAN, FINDINGS or nothing. The lines are what read -r gives for a here-string of the
    // text (the text split at each newline, its last line included); each is lower-cased and trimmed of
    // [[:space:]], then compared with the lower-cased marker. FINDINGS wins as soon as it is seen.
    public static string ReviewResultMarker(ReadOnlySpan<byte> text, string cleanMarker, string findingsMarker)
    {
        byte[] cleanLine = MarkerLine(cleanMarker);
        byte[] findingsLine = MarkerLine(findingsMarker);
        bool seenClean = false;
        ReadOnlySpan<byte> rest = text;

        while (true)
        {
            int newline = rest.IndexOf((byte)'\n');
            ReadOnlySpan<byte> line = newline < 0 ? rest : rest[..newline];
            ReadOnlySpan<byte> trimmed = ShellText.Trim(ShellText.ToLowerAscii(line));

            if (trimmed.SequenceEqual(findingsLine))
            {
                return "FINDINGS";
            }

            seenClean |= trimmed.SequenceEqual(cleanLine);

            if (newline < 0)
            {
                return seenClean ? "CLEAN" : string.Empty;
            }

            rest = rest[(newline + 1)..];
        }
    }

    // claude_result_indicates_clean_review
    public static bool CleanReview(ReadOnlySpan<byte> text, SessionTextPatterns patterns)
    {
        EreProgram cleanProgram = EreProgram.Compile(patterns.Clean);
        EreProgram findingsProgram = EreProgram.Compile(patterns.Findings);
        EreProgram negatedProgram = EreProgram.Compile(patterns.Negated);
        string marker = ReviewResultMarker(
            text: text,
            cleanMarker: patterns.CleanMarker,
            findingsMarker: patterns.FindingsMarker
        );

        if (text.IsEmpty || StringComparer.Ordinal.Equals(x: marker, y: "FINDINGS"))
        {
            return false;
        }

        if (StringComparer.Ordinal.Equals(x: marker, y: "CLEAN"))
        {
            return true;
        }

        return cleanProgram.IsMatch(text)
            && !findingsProgram.IsMatch(WithoutNegated(text: text, negated: negatedProgram));
    }

    // ${text,,}, then each match of negated in turn replaced by a space. A match that is empty or a lone space would
    // make bash's loop run for ever, so it is refused.
    private static byte[] WithoutNegated(ReadOnlySpan<byte> text, EreProgram negated)
    {
        byte[] lowered = ShellText.ToLowerAscii(text);
        int limit = lowered.Length + 1;

        int round = 0;

        while (true)
        {
            (int Start, int Length)? match = negated.FindLeftmostLongest(lowered);

            if (match is null)
            {
                return lowered;
            }

            ReadOnlySpan<byte> matched = lowered.AsSpan(start: match.Value.Start, length: match.Value.Length);

            if (round > limit || matched.IsEmpty || matched.SequenceEqual(" "u8))
            {
                throw new PodmanRefusedException(
                    "a negated pattern matches an empty string or a lone space, so bash's removal loop never ends"
                );
            }

            round++;
            int first = lowered.AsSpan().IndexOf(matched);
            lowered = [.. lowered.AsSpan(0, first), (byte)' ', .. lowered.AsSpan(first + matched.Length)];
        }
    }

    private static byte[] MarkerLine(string marker)
    {
        byte[] line = new byte[marker.Length];

        for (int index = 0; index < marker.Length; index++)
        {
            line[index] = ShellText.ToLowerAscii((byte)marker[index]);
        }

        return line;
    }
}
