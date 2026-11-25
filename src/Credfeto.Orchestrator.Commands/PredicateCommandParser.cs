using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Credfeto.Orchestrator.Commands;

// predicate <name> [--option <value>]...: the lib/github-status predicates (#252), each reading its
// pull request or Issue JSON on stdin and the larger JSON inputs from files
public static class PredicateCommandParser
{
    public const string Verb = "predicate";

    public const string TrustedFile = "--trusted-file";
    public const string ReviewCommentsFile = "--review-comments-file";
    public const string IssueCommentsFile = "--issue-comments-file";
    public const string ExcludeLogin = "--exclude-login";
    public const string LastSeen = "--last-seen";
    public const string PerCommentMaximum = "--per-comment-max";
    public const string RequiredFile = "--required-file";
    public const string BaseRequiresChecks = "--base-requires-checks";
    public const string ReviewPipelineFinished = "--review-pipeline-finished";
    public const string Repository = "--repo";
    public const string Me = "--me";

    private static readonly IReadOnlyList<string> CommentOptions =
    [
        TrustedFile,
        ReviewCommentsFile,
        IssueCommentsFile,
        ExcludeLogin,
    ];

    private static readonly IReadOnlyDictionary<string, PredicateDefinition> Definitions = BuildDefinitions();

    public static IReadOnlyList<string> Names { get; } = [.. Definitions.Keys.Order(StringComparer.Ordinal)];

    public static PredicateCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !StringComparer.Ordinal.Equals(x: args[0], y: Verb))
        {
            error = "expected: predicate <name> [options]";

            return null;
        }

        if (!Definitions.TryGetValue(key: args[1], value: out PredicateDefinition? definition))
        {
            error = $"unknown predicate '{args[1]}'";

            return null;
        }

        Dictionary<string, string>? options = ParseOptions(args: args, definition: definition, error: out error);

        if (options is null)
        {
            return null;
        }

        string? missing = definition.Required.FirstOrDefault(required => !options.ContainsKey(required));

        if (missing is not null)
        {
            error = $"{args[1]} needs {missing}";

            return null;
        }

        return new(Kind: definition.Kind, Options: options);
    }

    private static Dictionary<string, string>? ParseOptions(
        IReadOnlyList<string> args,
        PredicateDefinition definition,
        out string error
    )
    {
        Dictionary<string, string> options = [with(StringComparer.Ordinal)];

        for (int index = 2; index < args.Count; index += 2)
        {
            string option = args[index];

            if (!definition.Options.Contains(value: option, comparer: StringComparer.Ordinal))
            {
                error = $"unknown option '{option}'";

                return null;
            }

            if (index + 1 >= args.Count)
            {
                error = $"{option} needs a value";

                return null;
            }

            string value = args[index + 1];

            if (StringComparer.Ordinal.Equals(x: option, y: PerCommentMaximum) && !IsCount(value))
            {
                error = $"{PerCommentMaximum} must be a whole number, not '{value}'";

                return null;
            }

            options[option] = value;
        }

        error = string.Empty;

        return options;
    }

    private static bool IsCount(string value)
    {
        return int.TryParse(s: value, style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out _);
    }

    private static Dictionary<string, PredicateDefinition> BuildDefinitions()
    {
        Dictionary<string, PredicateDefinition> definitions = [with(StringComparer.Ordinal)];
        AddCheckPredicates(definitions);
        AddCommentReads(definitions);
        AddPullRequestReads(definitions);
        AddIssuePredicates(definitions);

        return definitions;
    }

    private static void AddCheckPredicates(Dictionary<string, PredicateDefinition> definitions)
    {
        Add(definitions: definitions, name: "pr-has-placeholder-file", kind: PredicateKind.PR_HAS_PLACEHOLDER_FILE);
        Add(definitions: definitions, name: "pr-has-only-passed-checks", kind: PredicateKind.PR_HAS_ONLY_PASSED_CHECKS);
        Add(
            definitions: definitions,
            name: "pr-is-terminal",
            kind: PredicateKind.PR_IS_TERMINAL,
            options: [ReviewPipelineFinished]
        );
        Add(
            definitions: definitions,
            name: "pr-has-failed-required-check",
            kind: PredicateKind.PR_HAS_FAILED_REQUIRED_CHECK
        );
        Add(
            definitions: definitions,
            name: "pr-has-failed-check-of-unknown-requiredness",
            kind: PredicateKind.PR_HAS_FAILED_CHECK_OF_UNKNOWN_REQUIREDNESS
        );
        Add(definitions: definitions, name: "pr-has-pending-ci-checks", kind: PredicateKind.PR_HAS_PENDING_CI_CHECKS);
        Add(
            definitions: definitions,
            name: "pr-has-unaddressed-review-request",
            kind: PredicateKind.PR_HAS_UNADDRESSED_REVIEW_REQUEST
        );
        Add(definitions: definitions, name: "pr-needs-review-approval", kind: PredicateKind.PR_NEEDS_REVIEW_APPROVAL);
    }

    private static void AddCommentReads(Dictionary<string, PredicateDefinition> definitions)
    {
        Add(
            definitions: definitions,
            name: "pr-latest-trusted-comment-timestamp",
            kind: PredicateKind.PR_LATEST_TRUSTED_COMMENT_TIMESTAMP,
            options: CommentOptions
        );
        Add(
            definitions: definitions,
            name: "pr-unaddressed-trusted-comments",
            kind: PredicateKind.PR_UNADDRESSED_TRUSTED_COMMENTS,
            options: [.. CommentOptions, LastSeen, PerCommentMaximum],
            required: [PerCommentMaximum]
        );
    }

    private static void AddPullRequestReads(Dictionary<string, PredicateDefinition> definitions)
    {
        Add(
            definitions: definitions,
            name: "pr-annotate-required-checks",
            kind: PredicateKind.PR_ANNOTATE_REQUIRED_CHECKS,
            options: [RequiredFile, BaseRequiresChecks]
        );
        Add(definitions: definitions, name: "pr-env-block-image-sha", kind: PredicateKind.PR_ENV_BLOCK_IMAGE_SHA);
        Add(
            definitions: definitions,
            name: "pr-lowest-closing-issue",
            kind: PredicateKind.PR_LOWEST_CLOSING_ISSUE,
            options: [Repository],
            required: [Repository]
        );
    }

    private static void AddIssuePredicates(Dictionary<string, PredicateDefinition> definitions)
    {
        Add(definitions: definitions, name: "issue-has-plan-comment", kind: PredicateKind.ISSUE_HAS_PLAN_COMMENT);
        Add(
            definitions: definitions,
            name: "issue-has-human-plan-approval",
            kind: PredicateKind.ISSUE_HAS_HUMAN_PLAN_APPROVAL,
            options: [Me, TrustedFile]
        );
    }

    private static void Add(
        Dictionary<string, PredicateDefinition> definitions,
        string name,
        PredicateKind kind,
        IReadOnlyList<string>? options = null,
        IReadOnlyList<string>? required = null
    )
    {
        definitions.Add(key: name, value: new(Kind: kind, Options: options ?? [], Required: required ?? []));
    }
}
