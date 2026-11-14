using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Commands;

// github open-prs|open-pr-count --repo <owner/repo> --head <branch>
// github branch-requires-status-checks --repo <owner/repo> --branch <branch>
public static class GitHubCommandParser
{
    public const string Verb = "github";

    private const string REPO = "--repo";
    private const string HEAD = "--head";
    private const string BRANCH = "--branch";

    public static GitHubCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !StringComparer.Ordinal.Equals(x: args[0], y: Verb))
        {
            error = "expected: github open-prs|open-pr-count|branch-requires-status-checks [options]";

            return null;
        }

        GitHubRead? read = ParseRead(args[1]);

        if (read is null)
        {
            error = $"unknown github read '{args[1]}': expected open-prs, open-pr-count or branch-requires-status-checks";

            return null;
        }

        return ParseOptions(args: args, read: read.Value, error: out error);
    }

    private static GitHubRead? ParseRead(string read)
    {
        return read switch
        {
            "open-prs" => GitHubRead.OPEN_PULL_REQUESTS,
            "open-pr-count" => GitHubRead.OPEN_PULL_REQUEST_COUNT,
            "branch-requires-status-checks" => GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS,
            _ => null,
        };
    }

    private static GitHubCommand? ParseOptions(IReadOnlyList<string> args, GitHubRead read, out string error)
    {
        string nameOption = read == GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS ? BRANCH : HEAD;
        string? repository = null;
        string? name = null;

        for (int index = 2; index < args.Count; index += 2)
        {
            string option = args[index];

            if (index + 1 >= args.Count)
            {
                error = $"{option} needs a value";

                return null;
            }

            if (StringComparer.Ordinal.Equals(x: option, y: REPO))
            {
                repository = args[index + 1];
            }
            else if (StringComparer.Ordinal.Equals(x: option, y: nameOption))
            {
                name = args[index + 1];
            }
            else
            {
                error = $"unknown option '{option}'";

                return null;
            }
        }

        return Complete(read: read, repository: repository, nameOption: nameOption, name: name, error: out error);
    }

    private static GitHubCommand? Complete(
        GitHubRead read,
        string? repository,
        string nameOption,
        string? name,
        out string error
    )
    {
        if (string.IsNullOrEmpty(repository))
        {
            error = $"{REPO} is required";

            return null;
        }

        if (string.IsNullOrEmpty(name))
        {
            error = $"{nameOption} is required";

            return null;
        }

        error = string.Empty;

        return new(Read: read, Repository: repository, Name: name);
    }
}
