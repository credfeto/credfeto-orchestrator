using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Credfeto.Orchestrator.State;

// state <query> --<option> <value> ...: every option the query takes, each once, in any order; a value may be empty,
// as the lib/state function's argument may be
public static class StateCommandParser
{
    public const string Verb = "state";

    public const string PullRequest = "PullRequest";
    public const string Issue = "Issue";

    public const string SessionDirectory = "session-dir";
    public const string StateDirectory = "state-dir";
    public const string Owner = "owner";
    public const string ItemType = "type";
    public const string ItemId = "id";
    public const string Kind = "kind";
    public const string Key = "key";
    public const string Sha = "sha";
    public const string MinSamples = "min-samples";
    public const string File = "file";
    public const string Count = "count";
    public const string Total = "total";
    public const string Idle = "idle";
    public const string Reset = "reset";
    public const string Status = "status";

    private const string OPTION_PREFIX = "--";

    // The markers lib/state tests with [ -f ]: <type>_<id>.<kind>
    private static readonly string[] MarkerKinds = ["plan-block", "blocked-replan", "background-stall"];

    private static readonly IReadOnlyDictionary<string, Definition> Queries = new Dictionary<string, Definition>(
        StringComparer.Ordinal
    )
    {
        ["infra-failures"] = new(StateQuery.INFRA_FAILURES, [SessionDirectory, ItemType, ItemId]),
        ["invocations"] = new(StateQuery.INVOCATIONS, [SessionDirectory, ItemType, ItemId]),
        ["env-unblock-attempts"] = new(StateQuery.ENV_UNBLOCK_ATTEMPTS, [SessionDirectory, ItemId]),
        ["marker"] = new(StateQuery.MARKER, [SessionDirectory, ItemType, ItemId, Kind]),
        ["last-diagnostic"] = new(StateQuery.LAST_DIAGNOSTIC, [SessionDirectory, ItemType, ItemId]),
        ["precheck-result"] = new(StateQuery.PRECHECK_RESULT, [SessionDirectory, Key, Sha]),
        ["pull-duration-baseline"] = new(StateQuery.PULL_DURATION_BASELINE, [StateDirectory, Owner, MinSamples]),
        ["rate-limit"] = new(StateQuery.RATE_LIMIT, [StateDirectory, Owner]),
        ["session-denials-summary"] = new(StateQuery.SESSION_DENIALS_SUMMARY, [File]),
        ["save-infra-failures"] = new(StateQuery.SAVE_INFRA_FAILURES, [SessionDirectory, ItemType, ItemId, Count]),
        ["save-invocations"] = new(StateQuery.SAVE_INVOCATIONS, [SessionDirectory, ItemType, ItemId, Total, Idle]),
        ["save-env-unblock-attempts"] = new(StateQuery.SAVE_ENV_UNBLOCK_ATTEMPTS, [SessionDirectory, ItemId, Total]),
        ["save-rate-limit"] = new(StateQuery.SAVE_RATE_LIMIT, [StateDirectory, Owner, Reset]),
        ["save-precheck-result"] = new(StateQuery.SAVE_PRECHECK_RESULT, [SessionDirectory, Key, Sha, Status]),
        ["save-last-diagnostic"] = new(StateQuery.SAVE_LAST_DIAGNOSTIC, [SessionDirectory, ItemType, ItemId]),
    };

    public static string QueryNames => string.Join(separator: ", ", values: Queries.Keys);

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    public static StateCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !IsVerb(args))
        {
            error = "expected: state <query> --<option> <value> ..., the query one of " + QueryNames;

            return null;
        }

        if (!Queries.TryGetValue(key: args[1], value: out Definition? definition))
        {
            error = $"unknown state query '{args[1]}': expected one of {QueryNames}";

            return null;
        }

        Dictionary<string, string>? options = ParseOptions(args: args, definition: definition);

        if (options is null)
        {
            error = $"state {args[1]} needs {Describe(definition)}, each once, and nothing else";

            return null;
        }

        error = Check(query: definition.Query, options: options);

        return error.Length == 0 ? new(Query: definition.Query, Options: options) : null;
    }

    private static Dictionary<string, string>? ParseOptions(IReadOnlyList<string> args, Definition definition)
    {
        if (args.Count != 2 + definition.Options.Count * 2)
        {
            return null;
        }

        Dictionary<string, string> options = [with(StringComparer.Ordinal)];

        for (int index = 2; index < args.Count; index += 2)
        {
            string name = args[index];

            if (
                !name.StartsWith(value: OPTION_PREFIX, comparisonType: StringComparison.Ordinal)
                || !definition.Options.Contains(value: name[OPTION_PREFIX.Length..], comparer: StringComparer.Ordinal)
                || !options.TryAdd(key: name[OPTION_PREFIX.Length..], value: args[index + 1])
            )
            {
                return null;
            }
        }

        return options;
    }

    private static string Check(StateQuery query, IReadOnlyDictionary<string, string> options)
    {
        if (query is StateQuery.INVOCATIONS or StateQuery.SAVE_INVOCATIONS && !IsInvocationType(options[ItemType]))
        {
            string name = query == StateQuery.INVOCATIONS ? "invocations" : "save-invocations";

            return $"state {name} --type must be {PullRequest} or {Issue}";
        }

        if (query == StateQuery.MARKER && !MarkerKinds.Contains(value: options[Kind], comparer: StringComparer.Ordinal))
        {
            return "state marker --kind must be one of " + string.Join(separator: ", ", values: MarkerKinds);
        }

        return string.Empty;
    }

    private static bool IsInvocationType(string itemType)
    {
        return StringComparer.Ordinal.Equals(x: itemType, y: PullRequest)
            || StringComparer.Ordinal.Equals(x: itemType, y: Issue);
    }

    private static string Describe(Definition definition)
    {
        return string.Join(separator: ' ', values: definition.Options.Select(option => $"--{option} <value>"));
    }

    [DebuggerDisplay("Query={Query}")]
    private sealed record Definition(StateQuery Query, IReadOnlyList<string> Options);
}
