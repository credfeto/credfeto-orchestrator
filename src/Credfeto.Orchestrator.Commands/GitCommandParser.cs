using System;
using System.Collections.Generic;
using System.Linq;

namespace Credfeto.Orchestrator.Commands;

// git head-sha|current-branch|uncommitted-changes --repo <dir>
// git origin-branch-exists --repo <dir> --branch <branch>
// git commits-behind --repo <dir> --ref <ref> --upstream <ref>
// git stale-issue-branch --repo <dir> --issue <number>
// Every option is required and may be empty, as the lib/git function's argument may be
public static class GitCommandParser
{
    public const string Verb = "git";

    private const string REPO = "--repo";
    private const string BRANCH = "--branch";
    private const string REF = "--ref";
    private const string UPSTREAM = "--upstream";
    private const string ISSUE = "--issue";

    private const string QUERIES =
        "head-sha, current-branch, uncommitted-changes, origin-branch-exists, commits-behind or stale-issue-branch";

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    public static GitCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !StringComparer.Ordinal.Equals(x: args[0], y: Verb))
        {
            error = $"expected: git <query> [options], the query one of {QUERIES}";

            return null;
        }

        GitQuery? query = ParseQuery(args[1]);

        if (query is null)
        {
            error = $"unknown git query '{args[1]}': expected {QUERIES}";

            return null;
        }

        IReadOnlyList<string> required = RequiredOptions(query.Value);
        Dictionary<string, string>? options = ParseOptions(args: args, allowed: required, error: out error);

        if (options is null)
        {
            return null;
        }

        string? missing = required.FirstOrDefault(option => !options.ContainsKey(option));

        if (missing is not null)
        {
            error = $"git {args[1]} needs {missing}";

            return null;
        }

        return Complete(query: query.Value, options: options);
    }

    private static GitQuery? ParseQuery(string query)
    {
        return query switch
        {
            "head-sha" => GitQuery.HEAD_SHA,
            "current-branch" => GitQuery.CURRENT_BRANCH,
            "uncommitted-changes" => GitQuery.UNCOMMITTED_CHANGES,
            "origin-branch-exists" => GitQuery.ORIGIN_BRANCH_EXISTS,
            "commits-behind" => GitQuery.COMMITS_BEHIND,
            "stale-issue-branch" => GitQuery.STALE_ISSUE_BRANCH,
            _ => null,
        };
    }

    private static IReadOnlyList<string> RequiredOptions(GitQuery query)
    {
        return query switch
        {
            GitQuery.ORIGIN_BRANCH_EXISTS => [REPO, BRANCH],
            GitQuery.COMMITS_BEHIND => [REPO, REF, UPSTREAM],
            GitQuery.STALE_ISSUE_BRANCH => [REPO, ISSUE],
            _ => [REPO],
        };
    }

    private static Dictionary<string, string>? ParseOptions(
        IReadOnlyList<string> args,
        IReadOnlyList<string> allowed,
        out string error
    )
    {
        Dictionary<string, string> options = [with(StringComparer.Ordinal)];

        for (int index = 2; index < args.Count; index += 2)
        {
            string option = args[index];

            if (!allowed.Contains(value: option, comparer: StringComparer.Ordinal))
            {
                error = $"unknown option '{option}'";

                return null;
            }

            if (index + 1 >= args.Count)
            {
                error = $"{option} needs a value";

                return null;
            }

            options[option] = args[index + 1];
        }

        error = string.Empty;

        return options;
    }

    private static GitCommand Complete(GitQuery query, Dictionary<string, string> options)
    {
        string repository = options[REPO];

        return query switch
        {
            GitQuery.ORIGIN_BRANCH_EXISTS => new(Query: query, Repository: repository, Name: options[BRANCH]),
            GitQuery.COMMITS_BEHIND => new(
                Query: query,
                Repository: repository,
                Name: options[REF],
                Upstream: options[UPSTREAM]
            ),
            GitQuery.STALE_ISSUE_BRANCH => new(Query: query, Repository: repository, Name: options[ISSUE]),
            _ => new(Query: query, Repository: repository),
        };
    }
}
