using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// The daily session digest payload lib/discord builds from one day's summary and the day before's (each the compact
// JSON summarise_session_denials_day prints, or null): the totals with their change from the day before, then the
// per-repository lines and the top denied commands. Only input jq -c could have printed is taken, with every number a
// plain integer of at most 15 digits as for the other payloads' --argjson numbers, so each total and difference prints
// as jq prints it; anything else, and any input the jq program fails on, is refused, and bash builds (or fails to
// build) it with jq.
public static class DailyDigestPayload
{
    public const string NoSessionsText = "No sessions were recorded for this day.";
    public const string SessionsText = "Agent sessions, permission denials and stalled sessions for this day.";
    public const string NoRecordText = "no record for the day before";
    public const string NoneText = "none";

    private const string TITLE_PREFIX = "Daily session digest: ";
    private const int TITLE_LENGTH = 240;
    private const int FIELD_LENGTH = 1000;
    private const int REPOSITORY_LINES = 15;

    // Far deeper than any summary nests, and far inside both parsers' depth limits
    private const int MAX_DEPTH = 32;

    // The jq program's ($s // {...}) for a day with no summary
    private static readonly JqValue NoCounts = JqValue.FromObject([
        new(Name: "sessions", Value: JqValue.FromInteger(0)),
        new(Name: "denials", Value: JqValue.FromInteger(0)),
        new(Name: "stalled", Value: JqValue.FromInteger(0)),
        new(Name: "quits", Value: JqValue.FromInteger(0)),
        new(Name: "repos", Value: JqValue.EmptyArray),
        new(Name: "top_commands", Value: JqValue.EmptyArray),
    ]);

    public static JqValue Build(IReadOnlyDictionary<string, string> options)
    {
        JqValue summary = ParseSummary(options: options, name: DiscordCommandParser.Summary);
        JqValue previous = ParseSummary(options: options, name: DiscordCommandParser.Previous);

        try
        {
            return Digest(options: options, summary: summary, previous: previous);
        }
        catch (JqException exception)
        {
            throw new DiscordRefusedException(
                message: "the jq program fails on this summary",
                innerException: exception
            );
        }
    }

    private static JqValue Digest(IReadOnlyDictionary<string, string> options, JqValue summary, JqValue previous)
    {
        JqValue counts = JqOps.Alternative(value: summary, fallback: NoCounts);
        string title = TITLE_PREFIX + options[DiscordCommandParser.Owner] + ", " + options[DiscordCommandParser.Day];

        return DiscordPayloads.Embed(
            Property(name: "title", value: JqBuiltins.Take(value: JqValue.FromString(title), count: TITLE_LENGTH)),
            Property(name: "color", value: JqValue.FromInteger(DiscordPayloads.Blue)),
            Property(
                name: "description",
                value: JqValue.FromString(summary.Kind == JqKind.NULL ? NoSessionsText : SessionsText)
            ),
            Property(
                name: "fields",
                value: JqValue.FromArray([
                    Total(name: "Sessions", key: "sessions", counts: counts, previous: previous),
                    Total(name: "Denials", key: "denials", counts: counts, previous: previous),
                    Total(name: "Stalled sessions", key: "stalled", counts: counts, previous: previous),
                    Field(
                        name: "Quit after a tool denial",
                        value: JqOps.ToText(JqOps.Field(value: counts, name: "quits")),
                        inline: true
                    ),
                    Field(name: "Per repository", value: RepositoryLines(counts), inline: false),
                    Field(name: "Top denied commands", value: CommandLines(counts), inline: false),
                ])
            )
        );
    }

    // "\($c.x) (\(delta($c.x; $p.x)))", inline
    private static JqValue Total(string name, string key, JqValue counts, JqValue previous)
    {
        JqValue current = JqOps.Field(value: counts, name: key);
        string change = Delta(current: current, previous: JqOps.Field(value: previous, name: key));

        return Field(name: name, value: $"{JqOps.ToText(current)} ({change})", inline: true);
    }

    // The jq program's delta def: no record when the day before has no value, else the signed difference
    private static string Delta(JqValue current, JqValue previous)
    {
        if (previous.Kind == JqKind.NULL)
        {
            return NoRecordText;
        }

        if (current.Kind != JqKind.NUMBER || previous.Kind != JqKind.NUMBER)
        {
            throw new JqException($"{current.TypeName()} and {previous.TypeName()} cannot be subtracted");
        }

        long difference = Integer(current) - Integer(previous);
        string text = difference switch
        {
            > 0 => "+" + difference.ToString(CultureInfo.InvariantCulture),
            < 0 => difference.ToString(CultureInfo.InvariantCulture),
            _ => "no change",
        };

        return text + " vs the day before";
    }

    // Every repository's line, built before the first 15 are taken (so a repository jq fails on fails the digest
    // wherever it is), joined by newlines
    private static string RepositoryLines(JqValue counts)
    {
        List<string> lines = [.. Items(value: counts, name: "repos").Select(RepositoryLine)];

        return Listed(lines: [.. lines.Take(REPOSITORY_LINES)], separator: "\n");
    }

    // "\(.repo): \(.denials) denial(s), \(.stalled) stalled, \(.sessions) session(s)"
    private static string RepositoryLine(JqValue repository)
    {
        string name = Interpolated(value: repository, name: "repo");
        string denials = Interpolated(value: repository, name: "denials");
        string stalled = Interpolated(value: repository, name: "stalled");
        string sessions = Interpolated(value: repository, name: "sessions");

        return $"{name}: {denials} denial(s), {stalled} stalled, {sessions} session(s)";
    }

    // Every command's "\(.name) (\(.count))", joined by commas
    private static string CommandLines(JqValue counts)
    {
        List<string> lines = [.. Items(value: counts, name: "top_commands").Select(CommandLine)];

        return Listed(lines: lines, separator: ", ");
    }

    private static string CommandLine(JqValue command)
    {
        return $"{Interpolated(value: command, name: "name")} ({Interpolated(value: command, name: "count")})";
    }

    // if length == 0 then "none" else (join(separator) | .[0:1000]) end
    private static string Listed(IReadOnlyList<string> lines, string separator)
    {
        if (lines.Count == 0)
        {
            return NoneText;
        }

        JqValue joined = JqValue.FromString(string.Join(separator: separator, values: lines));

        return JqBuiltins.Take(value: joined, count: FIELD_LENGTH).Text;
    }

    // $c.<name>[], taken only from an array: jq fails on null and iterates an object's values, which no summary holds
    private static IReadOnlyList<JqValue> Items(JqValue value, string name)
    {
        JqValue items = JqOps.Field(value: value, name: name);

        if (items.Kind != JqKind.ARRAY)
        {
            throw new JqException($"Cannot iterate over {items.TypeName()}");
        }

        return items.Items;
    }

    private static string Interpolated(JqValue value, string name)
    {
        return JqOps.ToText(JqOps.Field(value: value, name: name));
    }

    private static long Integer(JqValue number)
    {
        return long.Parse(s: number.Text, style: NumberStyles.AllowLeadingSign, provider: CultureInfo.InvariantCulture);
    }

    // The --argjson value: null, or JSON exactly as jq -c prints it (so no space, repeated key or other spelling jq
    // might read its own way) whose every number is a plain integer
    private static JqValue ParseSummary(IReadOnlyDictionary<string, string> options, string name)
    {
        string text = options[name];
        JqValue value;

        try
        {
            value = JqParser.Parse(text);
        }
        catch (JqException exception)
        {
            throw new DiscordRefusedException(message: $"--{name} is not JSON", innerException: exception);
        }

        if (!StringComparer.Ordinal.Equals(x: JqFormatter.ToJson(value), y: text))
        {
            throw new DiscordRefusedException($"--{name} is not compact JSON as jq -c prints it");
        }

        if (!HasOnlyPlainIntegers(value: value, depth: 0))
        {
            throw new DiscordRefusedException(
                $"--{name} holds a number that is not a plain integer, or nests too deep"
            );
        }

        return value;
    }

    private static bool HasOnlyPlainIntegers(JqValue value, int depth)
    {
        if (depth > MAX_DEPTH)
        {
            return false;
        }

        return value.Kind switch
        {
            JqKind.NUMBER => IsPlainInteger(value.Text),
            JqKind.ARRAY => value.Items.All(item => HasOnlyPlainIntegers(value: item, depth: depth + 1)),
            JqKind.DICTIONARY => value.Properties.All(property =>
                HasOnlyPlainIntegers(value: property.Value, depth: depth + 1)
            ),
            _ => true,
        };
    }

    // A plain integer as the --argjson numbers of the other payloads must be
    private static bool IsPlainInteger(string text)
    {
        bool negative = text.Length > 0 && text[0] == '-';

        return DiscordPayloads.IsPlainInteger(digits: negative ? text.AsSpan(1) : text.AsSpan(), negative: negative);
    }

    private static JqValue Field(string name, string value, bool inline)
    {
        return DiscordPayloads.Field(name: name, value: JqValue.FromString(value), inline: inline);
    }

    private static JqProperty Property(string name, JqValue value)
    {
        return new(Name: name, Value: value);
    }
}
