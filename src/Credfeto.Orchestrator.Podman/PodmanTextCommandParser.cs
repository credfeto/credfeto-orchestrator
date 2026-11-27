using System;
using System.Collections.Generic;
using System.Linq;

namespace Credfeto.Orchestrator.Podman;

// podman background-stall|diagnostic-refusal --ctype <name> --collate <name> --pattern <ere>
// podman tool-denied-quit --ctype <name> --collate <name> --mention <ere> --give-up <ere> --workaround <ere>
//     --negated <ere>
// podman review-result-marker --ctype <name> --collate <name> --clean-marker <line> --findings-marker <line>
// podman clean-review --ctype <name> --collate <name> --clean-marker <line> --findings-marker <line> --clean <ere>
//     --findings <ere> --negated <ere>
// The message is on stdin. Every option is required, once, in any order, and may be empty.
public static class PodmanTextCommandParser
{
    public const string CTYPE = "ctype";
    public const string COLLATE = "collate";
    public const string PATTERN = "pattern";
    public const string MENTION = "mention";
    public const string GIVE_UP = "give-up";
    public const string WORKAROUND = "workaround";
    public const string NEGATED = "negated";
    public const string CLEAN_MARKER = "clean-marker";
    public const string FINDINGS_MARKER = "findings-marker";
    public const string CLEAN = "clean";
    public const string FINDINGS = "findings";

    // Every text query name Parse accepts; the tool's --capabilities lists them (Names)
    private static readonly IReadOnlyDictionary<string, PodmanTextQuery> ByName = new Dictionary<
        string,
        PodmanTextQuery
    >(StringComparer.Ordinal)
    {
        ["background-stall"] = PodmanTextQuery.BACKGROUND_STALL,
        ["diagnostic-refusal"] = PodmanTextQuery.DIAGNOSTIC_REFUSAL,
        ["tool-denied-quit"] = PodmanTextQuery.TOOL_DENIED_QUIT,
        ["review-result-marker"] = PodmanTextQuery.REVIEW_RESULT_MARKER,
        ["clean-review"] = PodmanTextQuery.CLEAN_REVIEW,
    };

    public static IReadOnlyList<string> Names { get; } = [.. ByName.Keys.Order(StringComparer.Ordinal)];

    public static bool IsQuery(IReadOnlyList<string> args)
    {
        return args.Count > 1 && PodmanCommandParser.IsVerb(args) && ParseQuery(args[1]) is not null;
    }

    public static PodmanTextCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        PodmanTextQuery? query = args.Count > 1 && PodmanCommandParser.IsVerb(args) ? ParseQuery(args[1]) : null;

        if (query is null)
        {
            error = "expected: podman <text query> --<option> <value>...";

            return null;
        }

        string[] expected = OptionsFor(query.Value);
        Dictionary<string, string> options = [with(StringComparer.Ordinal)];

        for (int index = 2; index + 1 < args.Count; index += 2)
        {
            string name = args[index].StartsWith("--", StringComparison.Ordinal) ? args[index][2..] : string.Empty;

            if (
                !expected.Contains(value: name, comparer: StringComparer.Ordinal)
                || !options.TryAdd(key: name, value: args[index + 1])
            )
            {
                break;
            }
        }

        if (args.Count % 2 != 0 || options.Count != expected.Length || (args.Count - 2) / 2 != expected.Length)
        {
            string needed = string.Join(separator: ' ', values: expected.Select(name => "--" + name + " <value>"));
            error = $"podman {args[1]} needs {needed}, each once, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Query: query.Value, Options: options);
    }

    private static string[] OptionsFor(PodmanTextQuery query)
    {
        return query switch
        {
            PodmanTextQuery.TOOL_DENIED_QUIT => [CTYPE, COLLATE, MENTION, GIVE_UP, WORKAROUND, NEGATED],
            PodmanTextQuery.REVIEW_RESULT_MARKER => [CTYPE, COLLATE, CLEAN_MARKER, FINDINGS_MARKER],
            PodmanTextQuery.CLEAN_REVIEW => [CTYPE, COLLATE, CLEAN_MARKER, FINDINGS_MARKER, CLEAN, FINDINGS, NEGATED],
            _ => [CTYPE, COLLATE, PATTERN],
        };
    }

    private static PodmanTextQuery? ParseQuery(string query)
    {
        return ByName.TryGetValue(key: query, value: out PodmanTextQuery value) ? value : null;
    }
}
