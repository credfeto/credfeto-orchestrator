using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Text;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.State;

// summarise_session_denials_day's jq program over one per-day session-denials file (jq -R -s -c):
//   [split("\n")[] | select(length > 0) | split("\t") | select(length >= 8)
//       | {repo: .[1], denials: ((.[4] | tonumber?) // 0), stalled: (.[5] == "1"), quit: (.[6] == "1"),
//          commands: (if .[7] == "-" then [] else (.[7] | split(",")) end)}] as $s
//   | {sessions, denials, stalled, quits, repos (by repository, most denials first), top_commands (the five most
//      often denied command names)}
// Only a denial count jq's tonumber is sure to read as this does is taken: digits (up to 15, so a double holds
// them exactly) are the number, and a field with no digit and no nan or inf in it is 0; anything else is refused.
public static class SessionDenialsSummary
{
    private const int FIELDS = 8;
    private const int LONGEST_EXACT_COUNT = 15;
    private const int TOP_COMMANDS = 5;

    // 2^53: above it a jq sum is no longer exact
    private const long LARGEST_EXACT_SUM = 9007199254740992;

    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true
    );

    public static string DecodeUtf8(ReadOnlySpan<byte> content, string path)
    {
        try
        {
            return StrictUtf8.GetString(content);
        }
        catch (DecoderFallbackException exception)
        {
            // jq -R would read the bad bytes as U+FFFD
            throw new StateRefusedException(message: path + " is not UTF-8", innerException: exception);
        }
    }

    public static string Summarise(string text)
    {
        IReadOnlyList<Session> sessions =
        [
            .. text.Split('\n')
                .Where(line => line.Length > 0)
                .Select(line => line.Split('\t'))
                .Where(fields => fields.Length >= FIELDS)
                .Select(fields => new Session(
                    Repository: fields[1],
                    Denials: Denials(fields[4]),
                    Stalled: IsOne(fields[5]),
                    Quit: IsOne(fields[6]),
                    Commands: Commands(fields[7])
                )),
        ];

        JqValue summary = JqValue.FromObject([
            Integer(name: "sessions", value: sessions.Count),
            Integer(name: "denials", value: Sum(sessions)),
            Integer(name: "stalled", value: sessions.Count(session => session.Stalled)),
            Integer(name: "quits", value: sessions.Count(session => session.Quit)),
            new(Name: "repos", Value: JqValue.FromArray(Repositories(sessions))),
            new(Name: "top_commands", Value: JqValue.FromArray(TopCommands(sessions))),
        ]);

        return JqFormatter.ToJson(summary);
    }

    private static IReadOnlyList<JqValue> Repositories(IReadOnlyList<Session> sessions)
    {
        return
        [
            .. sessions
                .GroupBy(session => session.Repository, StringComparer.Ordinal)
                .Select(group => new RepositoryTotals(
                    Repository: group.Key,
                    Sessions: group.Count(),
                    Denials: Sum([.. group]),
                    Stalled: group.Count(session => session.Stalled)
                ))
                .OrderByDescending(totals => totals.Denials)
                .ThenByDescending(totals => totals.Stalled)
                .ThenBy(totals => totals.Repository, JqStringComparer.Instance)
                .Select(totals =>
                    JqValue.FromObject([
                        new(Name: "repo", Value: JqValue.FromString(totals.Repository)),
                        Integer(name: "sessions", value: totals.Sessions),
                        Integer(name: "denials", value: totals.Denials),
                        Integer(name: "stalled", value: totals.Stalled),
                    ])
                ),
        ];
    }

    private static IReadOnlyList<JqValue> TopCommands(IReadOnlyList<Session> sessions)
    {
        return
        [
            .. sessions
                .SelectMany(session => session.Commands)
                .GroupBy(name => name, StringComparer.Ordinal)
                .Select(group => (Name: group.Key, Count: group.Count()))
                .OrderByDescending(command => command.Count)
                .ThenBy(command => command.Name, JqStringComparer.Instance)
                .Take(TOP_COMMANDS)
                .Select(command =>
                    JqValue.FromObject([
                        new(Name: "name", Value: JqValue.FromString(command.Name)),
                        Integer(name: "count", value: command.Count),
                    ])
                ),
        ];
    }

    private static long Sum(IReadOnlyList<Session> sessions)
    {
        long total = 0;

        foreach (Session session in sessions)
        {
            total += session.Denials;

            if (total > LARGEST_EXACT_SUM)
            {
                throw new StateRefusedException("the denial counts add up to more than jq holds exactly");
            }
        }

        return total;
    }

    // (.[4] | tonumber?) // 0
    private static long Denials(string field)
    {
        if (field.Length <= LONGEST_EXACT_COUNT && StateText.IsDigits(field.AsSpan()))
        {
            return long.Parse(s: field, provider: CultureInfo.InvariantCulture);
        }

        if (
            field.AsSpan().ContainsAnyInRange(lowInclusive: '0', highInclusive: '9')
            || field.Contains("nan", StringComparison.OrdinalIgnoreCase)
            || field.Contains("inf", StringComparison.OrdinalIgnoreCase)
        )
        {
            throw new StateRefusedException("a denial count jq's tonumber may read differently: " + field);
        }

        return 0;
    }

    private static bool IsOne(string field)
    {
        return StringComparer.Ordinal.Equals(x: field, y: "1");
    }

    // if .[7] == "-" then [] else (.[7] | split(",")) end, where jq splits "" into no names at all
    private static IReadOnlyList<string> Commands(string field)
    {
        return field.Length == 0 || StringComparer.Ordinal.Equals(x: field, y: "-") ? [] : field.Split(',');
    }

    private static JqProperty Integer(string name, long value)
    {
        return new(Name: name, Value: JqValue.FromInteger(value));
    }

    [DebuggerDisplay("Repository={Repository}, Denials={Denials}")]
    private sealed record Session(
        string Repository,
        long Denials,
        bool Stalled,
        bool Quit,
        IReadOnlyList<string> Commands
    );

    [DebuggerDisplay("Repository={Repository}, Denials={Denials}")]
    private sealed record RepositoryTotals(string Repository, int Sessions, long Denials, int Stalled);
}
