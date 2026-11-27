using System;
using System.Collections.Generic;
using System.Linq;

namespace Credfeto.Orchestrator.Predicates;

// checks next-phase --board-status <status> --required-checks-unknown <true|false>  (pull request JSON on stdin)
// checks merge-state-allows-settled --merge-state <state>                         (pull request JSON on stdin)
// checks session-progress-reason --pre-board <status> --post-board <status> --pre-comment-ts <time>
//     --post-comment-ts <time> --pre-head <sha> --post-head <sha>
// checks clean-review-comment --status <status>
// checks has-blocked-label                                         (pull request or Issue JSON on stdin)
// checks priority-for-labels                                       (a labels JSON array on stdin)
// Every option is required, once, in any order, and may be empty, as the shell function's argument may be.
public static class ChecksCommandParser
{
    public const string Verb = "checks";

    public const string BOARD_STATUS = "board-status";
    public const string REQUIRED_CHECKS_UNKNOWN = "required-checks-unknown";
    public const string MERGE_STATE = "merge-state";
    public const string PRE_BOARD = "pre-board";
    public const string POST_BOARD = "post-board";
    public const string PRE_COMMENT_TS = "pre-comment-ts";
    public const string POST_COMMENT_TS = "post-comment-ts";
    public const string PRE_HEAD = "pre-head";
    public const string POST_HEAD = "post-head";
    public const string STATUS = "status";

    private const string QUERIES =
        "next-phase, merge-state-allows-settled, session-progress-reason, clean-review-comment, has-blocked-label "
        + "or priority-for-labels";

    // Every query name Parse accepts; the tool's --capabilities lists them (Names)
    private static readonly IReadOnlyDictionary<string, ChecksQuery> ByName = new Dictionary<string, ChecksQuery>(
        StringComparer.Ordinal
    )
    {
        ["next-phase"] = ChecksQuery.NEXT_PHASE,
        ["merge-state-allows-settled"] = ChecksQuery.MERGE_STATE_ALLOWS_SETTLED,
        ["session-progress-reason"] = ChecksQuery.SESSION_PROGRESS_REASON,
        ["clean-review-comment"] = ChecksQuery.CLEAN_REVIEW_COMMENT,
        ["has-blocked-label"] = ChecksQuery.HAS_BLOCKED_LABEL,
        ["priority-for-labels"] = ChecksQuery.PRIORITY_FOR_LABELS,
    };

    public static IReadOnlyList<string> Names { get; } = [.. ByName.Keys.Order(StringComparer.Ordinal)];

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    // Whether the query reads JSON on stdin; the others never read it
    public static bool ReadsInput(ChecksQuery query)
    {
        return query
            is ChecksQuery.NEXT_PHASE
                or ChecksQuery.MERGE_STATE_ALLOWS_SETTLED
                or ChecksQuery.HAS_BLOCKED_LABEL
                or ChecksQuery.PRIORITY_FOR_LABELS;
    }

    public static ChecksCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !IsVerb(args))
        {
            error = $"expected: checks <query> --<option> <value>..., the query one of {QUERIES}";

            return null;
        }

        if (!ByName.TryGetValue(key: args[1], value: out ChecksQuery query))
        {
            error = $"unknown checks query '{args[1]}': expected {QUERIES}";

            return null;
        }

        string[] expected = OptionsFor(query);
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

        if (args.Count != 2 + 2 * expected.Length || options.Count != expected.Length)
        {
            string needed = string.Join(separator: ' ', values: expected.Select(name => "--" + name + " <value>"));
            error =
                expected.Length == 0
                    ? $"checks {args[1]} takes no options"
                    : $"checks {args[1]} needs {needed}, each once, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Query: query, Options: options);
    }

    private static string[] OptionsFor(ChecksQuery query)
    {
        return query switch
        {
            ChecksQuery.NEXT_PHASE => [BOARD_STATUS, REQUIRED_CHECKS_UNKNOWN],
            ChecksQuery.MERGE_STATE_ALLOWS_SETTLED => [MERGE_STATE],
            ChecksQuery.SESSION_PROGRESS_REASON =>
            [
                PRE_BOARD,
                POST_BOARD,
                PRE_COMMENT_TS,
                POST_COMMENT_TS,
                PRE_HEAD,
                POST_HEAD,
            ],
            ChecksQuery.CLEAN_REVIEW_COMMENT => [STATUS],
            _ => [],
        };
    }
}
