using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// lib/discord's _build_no_work_item_breakdown: jq -r turns each item into an @tsv row of type, id, repo and reason,
// bash reads each row back with IFS=$'\t' read -r, builds "- [<type> #<id> in <repo>](<url>): <reason>" and keeps
// lines while their lengths (each plus its newline) fit the budget, then says how many it left out
public static class NoWorkBreakdown
{
    // Headroom under Discord's 4096-character embed description for the trailer line
    public const int Budget = 3900;

    private static readonly string[] Fields = ["type", "id", "repo", "reason"];

    public static LengthUnit ParseUnit(string unit)
    {
        return unit switch
        {
            "characters" => LengthUnit.CHARACTERS,
            "bytes" => LengthUnit.BYTES,
            _ => throw new DiscordRefusedException(
                $"--length-unit {unit}: the shell's locale counts neither characters nor bytes"
            ),
        };
    }

    public static string Build(JqInput input, string defaultRepo, LengthUnit unit)
    {
        IReadOnlyList<IReadOnlyList<string>> rows = Rows(input);

        if (rows.Count == 0)
        {
            return string.Empty;
        }

        List<string> kept = [];
        long used = 0;

        foreach (IReadOnlyList<string> row in rows)
        {
            string line = Line(row: row, defaultRepo: defaultRepo);
            long length = Length(text: line, unit: unit) + 1;

            if (used + length > Budget)
            {
                break;
            }

            kept.Add(line);
            used += length;
        }

        string description = string.Join(separator: '\n', values: kept);

        return kept.Count < rows.Count
            ? description
                + string.Create(
                    provider: CultureInfo.InvariantCulture,
                    $"\n... and {rows.Count - kept.Count} more (see the journal for full detail)"
                )
            : description;
    }

    // What jq's @tsv rows hold, as read back: no input text prints nothing; one array of objects or nulls gives one
    // row each. Anything else jq fails on part-way, or reads in a way not worth copying, so it is refused
    private static IReadOnlyList<IReadOnlyList<string>> Rows(JqInput input)
    {
        if (input.Values.Count == 0)
        {
            return [];
        }

        if (input.Values.Count != 1 || input.Values[0].Kind != JqKind.ARRAY)
        {
            throw new DiscordRefusedException("the items are not one JSON array");
        }

        return [.. input.Values[0].Items.Select(Row)];
    }

    // The four cells of one item's row, after IFS=$'\t' read -r: a tab run is one separator and leading and
    // trailing tabs are dropped, so empty cells fall away and the cells after them move left
    private static IReadOnlyList<string> Row(JqValue item)
    {
        if (item.Kind is not (JqKind.DICTIONARY or JqKind.NULL))
        {
            throw new DiscordRefusedException($"an item is {item.TypeName()}, not an object");
        }

        List<string> cells =
        [
            .. Fields.Select(field => Cell(Field(item: item, name: field))).Where(cell => cell.Length > 0),
        ];

        while (cells.Count < Fields.Length)
        {
            cells.Add(string.Empty);
        }

        return cells;
    }

    // .name of an object (its last value for a repeated key, as the parser keeps), null when missing or for a null
    private static JqValue Field(JqValue item, string name)
    {
        for (int index = 0; index < item.Properties.Count; index++)
        {
            if (StringComparer.Ordinal.Equals(x: item.Properties[index].Name, y: name))
            {
                return item.Properties[index].Value;
            }
        }

        return JqValue.Null;
    }

    // One @tsv cell: null is empty, booleans and numbers as jq prints them (numbers are plain integers by now),
    // strings with backslash, tab, newline, carriage return and NUL escaped; an array or object fails @tsv
    private static string Cell(JqValue value)
    {
        return value.Kind switch
        {
            JqKind.NULL => string.Empty,
            JqKind.FALSE => "false",
            JqKind.TRUE => "true",
            JqKind.NUMBER => value.Text,
            JqKind.TEXT => Escape(value.Text),
            _ => throw new DiscordRefusedException($"a field is {value.TypeName()}, which @tsv refuses"),
        };
    }

    private static string Escape(string text)
    {
        StringBuilder builder = new(text.Length);

        foreach (char character in text)
        {
            AppendEscaped(builder: builder, character: character);
        }

        return builder.ToString();
    }

    private static void AppendEscaped(StringBuilder builder, char character)
    {
        switch (character)
        {
            case '\\':
                builder.Append(@"\\");

                break;
            case '\t':
                builder.Append(@"\t");

                break;
            case '\n':
                builder.Append(@"\n");

                break;
            case '\r':
                builder.Append(@"\r");

                break;
            case '\0':
                builder.Append(@"\0");

                break;
            default:
                builder.Append(character);

                break;
        }
    }

    private static string Line(IReadOnlyList<string> row, string defaultRepo)
    {
        string url = ItemUrl.Build(itemType: row[0], itemId: row[1], repo: row[2], defaultRepo: defaultRepo);

        return $"- [{row[0]} #{row[1]} in {row[2]}]({url}): {row[3]}";
    }

    private static long Length(string text, LengthUnit unit)
    {
        return unit == LengthUnit.BYTES ? Encoding.UTF8.GetByteCount(text) : text.EnumerateRunes().Count();
    }
}
