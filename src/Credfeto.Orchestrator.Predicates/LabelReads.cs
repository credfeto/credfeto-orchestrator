using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// The label reads over pre-fetched JSON: whether an item carries Blocked (_json_has_blocked_label, lib/github-status)
// and the priority its labels name (priority_for_labels, lib/workflow-board)
public static class LabelReads
{
    private const string BLOCKED = "blocked";

    private const string UNDEFINED = "Undefined";

    // priority_for_labels' tiers, highest first: the first a label name matches (case-insensitively) wins
    private static readonly IReadOnlyList<(string Name, string Priority)> Tiers =
    [
        ("security", "Security"),
        ("urgent", "Urgent"),
        ("high", "High"),
        ("medium", "Medium"),
        ("low", "Low"),
    ];

    // _json_has_blocked_label: jq -r '(.labels // [])[] | .name' piped to grep -qi '^blocked$'. Without pipefail
    // the answer is grep's, so it holds when any line jq printed, before any error, is "blocked" in any case: a
    // label name holding a newline is several lines. A name that is not a string never prints such a line (jq -r
    // prints it as JSON). Refused when a printed name holds a NUL byte (grep's binary handling) or a line of seven
    // characters with one outside ASCII, where grep -i's case folding in a UTF-8 locale would decide
    public static ChecksAnswer HasBlockedLabel(string json)
    {
        JqInput stream = JqParser.ParseStream(json);
        bool found = false;

        foreach (JqValue document in stream.Values)
        {
            foreach (JqValue name in LabelNames(document))
            {
                if (name.Kind != JqKind.TEXT)
                {
                    continue;
                }

                if (name.Text.Contains(value: '\0', comparisonType: StringComparison.Ordinal))
                {
                    return ChecksAnswer.Refused("a label name holds a NUL byte, which grep reads as binary data");
                }

                foreach (string line in name.Text.Split('\n'))
                {
                    if (IsUncertainFold(line))
                    {
                        return ChecksAnswer.Refused(
                            "a label name has a line of seven characters that are not all ASCII, which grep -i "
                                + "could fold to blocked"
                        );
                    }

                    found |= IsBlocked(line);
                }
            }
        }

        return ChecksAnswer.Of(found);
    }

    // priority_for_labels: what jq -r prints for each JSON text (a line naming the highest tier any label's name
    // matches, or Undefined), then Undefined when jq fails (a runtime error in the last text, or input that is not
    // JSON), as `|| printf 'Undefined'` adds it
    public static string PriorityForLabels(string labelsJson)
    {
        JqRun run = JqProgram.Run(input: labelsJson, program: static labels => JqValue.FromString(Priority(labels)));
        StringBuilder printed = new();

        foreach (JqValue output in run.Outputs)
        {
            printed.Append(JqFormatter.Raw(output)).Append('\n');
        }

        if (!run.Succeeded)
        {
            printed.Append(UNDEFINED);
        }

        return printed.ToString();
    }

    // (.labels // [])[] | .name, the names printed before the first error of the text; jq goes on with the next text
    private static List<JqValue> LabelNames(JqValue document)
    {
        List<JqValue> names = [];

        try
        {
            JqValue labels = JqOps.Alternative(
                value: JqOps.Field(value: document, name: "labels"),
                fallback: JqValue.EmptyArray
            );

            foreach (JqValue label in JqOps.Iterate(labels))
            {
                names.Add(JqOps.Field(value: label, name: "name"));
            }
        }
        catch (JqException)
        {
            // jq reports the error and prints nothing more for this text
        }

        return names;
    }

    // ([.[]?.name // empty | ascii_downcase]) as $names, then the first tier whose name $names holds
    private static string Priority(JqValue labels)
    {
        List<string> names = [];

        foreach (JqValue label in JqBuiltins.IterateOptional(labels))
        {
            JqValue name = JqOps.Field(value: label, name: "name");

            if (name.IsTruthy)
            {
                names.Add(JqBuiltins.AsciiDowncase(name).Text);
            }
        }

        return Tiers
            .Where(tier => names.Contains(value: tier.Name, comparer: StringComparer.Ordinal))
            .Select(static tier => tier.Priority)
            .FirstOrDefault()
            ?? UNDEFINED;
    }

    // grep -i '^blocked$' on an ASCII line: the line is blocked, any letter in either case
    private static bool IsBlocked(string line)
    {
        return IsAscii(line) && StringComparer.OrdinalIgnoreCase.Equals(x: line, y: BLOCKED);
    }

    private static bool IsUncertainFold(string line)
    {
        return !IsAscii(line) && line.EnumerateRunes().Take(BLOCKED.Length + 1).Count() == BLOCKED.Length;
    }

    private static bool IsAscii(string line)
    {
        return !line.AsSpan().ContainsAnyExceptInRange(lowInclusive: '\0', highInclusive: '\u007f');
    }
}
