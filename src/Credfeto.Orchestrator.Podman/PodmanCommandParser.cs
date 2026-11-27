using System;
using System.Collections.Generic;
using System.Linq;

namespace Credfeto.Orchestrator.Podman;

// podman image-sha|image-exists --image <image>
// podman container-exists|container-running --name <name>
// podman denials-summary|denied-command-names --result <file>
// (the text queries, which take several options, are parsed by PodmanTextCommandParser)
// The option is required and may be empty, as the lib/podman function's argument may be
public static class PodmanCommandParser
{
    public const string Verb = "podman";

    private const string IMAGE = "--image";
    private const string NAME = "--name";
    private const string RESULT = "--result";

    private const string QUERIES =
        "image-sha, container-exists, container-running, image-exists, denials-summary, denied-command-names, "
        + "background-stall, diagnostic-refusal, tool-denied-quit, review-result-marker or clean-review";

    // Every query name Parse accepts; the tool's --capabilities lists them (Names)
    private static readonly IReadOnlyDictionary<string, PodmanQuery> ByName = new Dictionary<string, PodmanQuery>(
        StringComparer.Ordinal
    )
    {
        ["image-sha"] = PodmanQuery.IMAGE_SHA,
        ["container-exists"] = PodmanQuery.CONTAINER_EXISTS,
        ["container-running"] = PodmanQuery.CONTAINER_RUNNING,
        ["image-exists"] = PodmanQuery.IMAGE_EXISTS,
        ["denials-summary"] = PodmanQuery.DENIALS_SUMMARY,
        ["denied-command-names"] = PodmanQuery.DENIED_COMMAND_NAMES,
    };

    public static IReadOnlyList<string> Names { get; } = [.. ByName.Keys.Order(StringComparer.Ordinal)];

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    public static PodmanCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !IsVerb(args))
        {
            error = $"expected: podman <query> <option> <value>, the query one of {QUERIES}";

            return null;
        }

        PodmanQuery? query = ParseQuery(args[1]);

        if (query is null)
        {
            error = $"unknown podman query '{args[1]}': expected {QUERIES}";

            return null;
        }

        string option = OptionFor(query.Value);

        if (args.Count != 4 || !StringComparer.Ordinal.Equals(x: args[2], y: option))
        {
            error = $"podman {args[1]} needs {option} <value>, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Query: query.Value, Argument: args[3]);
    }

    private static string OptionFor(PodmanQuery query)
    {
        return query switch
        {
            PodmanQuery.IMAGE_SHA or PodmanQuery.IMAGE_EXISTS => IMAGE,
            PodmanQuery.DENIALS_SUMMARY or PodmanQuery.DENIED_COMMAND_NAMES => RESULT,
            _ => NAME,
        };
    }

    private static PodmanQuery? ParseQuery(string query)
    {
        return ByName.TryGetValue(key: query, value: out PodmanQuery value) ? value : null;
    }
}
