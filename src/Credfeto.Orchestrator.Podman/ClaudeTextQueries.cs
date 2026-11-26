using System;
using System.Text;

namespace Credfeto.Orchestrator.Podman;

// Answers a session-outcome text query over the message on stdin, which lib/podman sends as a here-string, so it
// ends with the one newline the here-string adds. The heuristics answer with exit 0 (true) or 1 (false); the marker
// read prints CLEAN, FINDINGS or nothing with exit 0. Refused: input without that newline or holding a NUL (bash
// cannot hold one), a locale SessionTextLocale does not accept, a byte of 0x80 or more outside the C locale, and a
// pattern or marker that is not printable ASCII or that EreParser refuses.
public static class ClaudeTextQueries
{
    public static PodmanResult Answer(PodmanTextCommand command, ReadOnlySpan<byte> input)
    {
        ReadOnlySpan<byte> text = Message(command: command, input: input);

        return command.Query switch
        {
            PodmanTextQuery.TOOL_DENIED_QUIT => Status(
                SessionTextHeuristics.ToolDeniedQuit(
                    text: text,
                    mention: command.Option(PodmanTextCommandParser.MENTION),
                    giveUp: command.Option(PodmanTextCommandParser.GIVE_UP),
                    workaround: command.Option(PodmanTextCommandParser.WORKAROUND),
                    negated: command.Option(PodmanTextCommandParser.NEGATED)
                )
            ),
            PodmanTextQuery.REVIEW_RESULT_MARKER => new(
                ExitCode: 0,
                Output: Encoding.ASCII.GetBytes(
                    SessionTextHeuristics.ReviewResultMarker(
                        text: text,
                        cleanMarker: Marker(command: command, name: PodmanTextCommandParser.CLEAN_MARKER),
                        findingsMarker: Marker(command: command, name: PodmanTextCommandParser.FINDINGS_MARKER)
                    )
                )
            ),
            PodmanTextQuery.CLEAN_REVIEW => Status(
                SessionTextHeuristics.CleanReview(text: text, patterns: Patterns(command))
            ),
            _ => Status(
                SessionTextHeuristics.Matches(text: text, pattern: command.Option(PodmanTextCommandParser.PATTERN))
            ),
        };
    }

    private static ReadOnlySpan<byte> Message(PodmanTextCommand command, ReadOnlySpan<byte> input)
    {
        SessionTextLocale locale = SessionTextLocales.From(
            ctype: command.Option(PodmanTextCommandParser.CTYPE),
            collate: command.Option(PodmanTextCommandParser.COLLATE)
        ) ?? throw new PodmanRefusedException("the locale is not one whose matching the tool knows");

        if (input.IsEmpty || input[^1] != (byte)'\n')
        {
            throw new PodmanRefusedException("stdin does not end with the newline a here-string adds");
        }

        ReadOnlySpan<byte> text = input[..^1];

        if (text.Contains((byte)0))
        {
            throw new PodmanRefusedException("the message holds a NUL byte, which a bash variable cannot");
        }

        if (
            locale == SessionTextLocale.ASCII
            && text.IndexOfAnyExceptInRange(lowInclusive: (byte)0, highInclusive: (byte)0x7F) >= 0
        )
        {
            throw new PodmanRefusedException(
                "the message is not ASCII, and outside the C locale its matching depends on the locale data"
            );
        }

        return text;
    }

    private static SessionTextPatterns Patterns(PodmanTextCommand command)
    {
        return new(
            CleanMarker: Marker(command: command, name: PodmanTextCommandParser.CLEAN_MARKER),
            FindingsMarker: Marker(command: command, name: PodmanTextCommandParser.FINDINGS_MARKER),
            Clean: command.Option(PodmanTextCommandParser.CLEAN),
            Findings: command.Option(PodmanTextCommandParser.FINDINGS),
            Negated: command.Option(PodmanTextCommandParser.NEGATED)
        );
    }

    private static string Marker(PodmanTextCommand command, string name)
    {
        string marker = command.Option(name);

        return marker.AsSpan().ContainsAnyExceptInRange(lowInclusive: ' ', highInclusive: '~')
            ? throw new PodmanRefusedException("a review result marker is not printable ASCII")
            : marker;
    }

    private static PodmanResult Status(bool answer)
    {
        return new(ExitCode: answer ? 0 : 1, Output: ReadOnlyMemory<byte>.Empty);
    }
}
