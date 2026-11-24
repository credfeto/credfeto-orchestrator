using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Credfeto.Orchestrator.Commands;

// github open-prs|open-pr-count --repo <owner/repo> --head <branch>
// github branch-requires-status-checks --repo <owner/repo> --branch <branch>
// github own-open-prs --repo <owner/repo> --me <login> --creator <login> [--include-blocked true|false]
// github whoami
// github open-prs-closing-issues --repo <owner/repo>
// github pr-commit-authors --repo <owner/repo> --pr <number>
// github branch-behind-by --repo <owner/repo> --base <branch> --head <branch>
public static class GitHubCommandParser
{
    public const string Verb = "github";

    private const string REPO = "--repo";
    private const string HEAD = "--head";
    private const string BRANCH = "--branch";
    private const string ME = "--me";
    private const string CREATOR = "--creator";
    private const string INCLUDE_BLOCKED = "--include-blocked";
    private const string PR = "--pr";
    private const string BASE = "--base";

    private const string READS =
        "open-prs, open-pr-count, branch-requires-status-checks, own-open-prs, whoami, open-prs-closing-issues, "
        + "pr-commit-authors or branch-behind-by";

    public static GitHubCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !StringComparer.Ordinal.Equals(x: args[0], y: Verb))
        {
            error = "expected: github <read> [options], where <read> is " + READS;

            return null;
        }

        GitHubRead? read = ParseRead(args[1]);

        if (read is null)
        {
            error = $"unknown github read '{args[1]}': expected {READS}";

            return null;
        }

        Dictionary<string, string>? options = ParseOptions(args: args, read: read.Value, error: out error);

        return options is null ? null : Complete(read: read.Value, options: options, error: out error);
    }

    private static GitHubRead? ParseRead(string read)
    {
        return read switch
        {
            "open-prs" => GitHubRead.OPEN_PULL_REQUESTS,
            "open-pr-count" => GitHubRead.OPEN_PULL_REQUEST_COUNT,
            "branch-requires-status-checks" => GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS,
            "own-open-prs" => GitHubRead.OWN_OPEN_PULL_REQUESTS,
            "whoami" => GitHubRead.CURRENT_LOGIN,
            "open-prs-closing-issues" => GitHubRead.OPEN_PULL_REQUESTS_WITH_CLOSING_ISSUES,
            "pr-commit-authors" => GitHubRead.PULL_REQUEST_COMMIT_AUTHORS,
            "branch-behind-by" => GitHubRead.BRANCH_BEHIND_BY,
            _ => null,
        };
    }

    private static IReadOnlyList<string> AllowedOptions(GitHubRead read)
    {
        return read switch
        {
            GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS => [REPO, BRANCH],
            GitHubRead.OWN_OPEN_PULL_REQUESTS => [REPO, ME, CREATOR, INCLUDE_BLOCKED],
            GitHubRead.CURRENT_LOGIN => [],
            GitHubRead.OPEN_PULL_REQUESTS_WITH_CLOSING_ISSUES => [REPO],
            GitHubRead.PULL_REQUEST_COMMIT_AUTHORS => [REPO, PR],
            GitHubRead.BRANCH_BEHIND_BY => [REPO, BASE, HEAD],
            _ => [REPO, HEAD],
        };
    }

    private static Dictionary<string, string>? ParseOptions(
        IReadOnlyList<string> args,
        GitHubRead read,
        out string error
    )
    {
        IReadOnlyList<string> allowed = AllowedOptions(read);
        Dictionary<string, string> options = [with(StringComparer.Ordinal)];

        for (int index = 2; index < args.Count; index += 2)
        {
            string option = args[index];

            if (index + 1 >= args.Count)
            {
                error = $"{option} needs a value";

                return null;
            }

            if (!allowed.Contains(value: option, comparer: StringComparer.Ordinal))
            {
                error = $"unknown option '{option}'";

                return null;
            }

            options[option] = args[index + 1];
        }

        error = string.Empty;

        return options;
    }

    private static GitHubCommand? Complete(GitHubRead read, Dictionary<string, string> options, out string error)
    {
        if (read == GitHubRead.CURRENT_LOGIN)
        {
            error = string.Empty;

            return new(Read: read, Repository: string.Empty, Name: string.Empty);
        }

        string? repository = Required(options: options, option: REPO, error: out error);

        if (repository is null)
        {
            return null;
        }

        return read switch
        {
            GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS => Named(
                read: read,
                repository: repository,
                options: options,
                nameOption: BRANCH,
                error: out error
            ),
            GitHubRead.OWN_OPEN_PULL_REQUESTS => Own(repository: repository, options: options, error: out error),
            GitHubRead.OPEN_PULL_REQUESTS_WITH_CLOSING_ISSUES => new(
                Read: read,
                Repository: repository,
                Name: string.Empty
            ),
            GitHubRead.PULL_REQUEST_COMMIT_AUTHORS => Commits(
                repository: repository,
                options: options,
                error: out error
            ),
            GitHubRead.BRANCH_BEHIND_BY => Behind(repository: repository, options: options, error: out error),
            _ => Named(read: read, repository: repository, options: options, nameOption: HEAD, error: out error),
        };
    }

    private static GitHubCommand? Named(
        GitHubRead read,
        string repository,
        Dictionary<string, string> options,
        string nameOption,
        out string error
    )
    {
        string? name = Required(options: options, option: nameOption, error: out error);

        return name is null ? null : new(Read: read, Repository: repository, Name: name);
    }

    private static GitHubCommand? Own(string repository, Dictionary<string, string> options, out string error)
    {
        string? me = Required(options: options, option: ME, error: out error);

        if (me is null)
        {
            return null;
        }

        string? creator = Required(options: options, option: CREATOR, error: out error);

        if (creator is null)
        {
            return null;
        }

        bool? includeBlocked = IncludeBlocked(options: options, error: out error);

        return includeBlocked is null
            ? null
            : new(
                Read: GitHubRead.OWN_OPEN_PULL_REQUESTS,
                Repository: repository,
                Name: me,
                Creator: creator,
                IncludeBlocked: includeBlocked.Value
            );
    }

    private static GitHubCommand? Commits(string repository, Dictionary<string, string> options, out string error)
    {
        string? value = Required(options: options, option: PR, error: out error);

        if (value is null)
        {
            return null;
        }

        // Digits only, as gh pr view takes a pull request number: no sign, spaces or leading zeros
        if (value.Length > 9 || value[0] == '0' || !value.All(char.IsAsciiDigit))
        {
            error = $"{PR} must be a pull request number";

            return null;
        }

        return new(
            Read: GitHubRead.PULL_REQUEST_COMMIT_AUTHORS,
            Repository: repository,
            Name: string.Empty,
            PullRequest: int.Parse(s: value, provider: CultureInfo.InvariantCulture)
        );
    }

    private static GitHubCommand? Behind(string repository, Dictionary<string, string> options, out string error)
    {
        string? baseBranch = Required(options: options, option: BASE, error: out error);

        if (baseBranch is null)
        {
            return null;
        }

        string? head = Required(options: options, option: HEAD, error: out error);

        return head is null
            ? null
            : new(Read: GitHubRead.BRANCH_BEHIND_BY, Repository: repository, Name: head, Base: baseBranch);
    }

    // Matches list_bot_created_open_prs' second argument, which jq reads as JSON: only true and false are accepted
    private static bool? IncludeBlocked(Dictionary<string, string> options, out string error)
    {
        error = string.Empty;

        if (!options.TryGetValue(key: INCLUDE_BLOCKED, value: out string? value))
        {
            return false;
        }

        return value switch
        {
            "true" => true,
            "false" => false,
            _ => Invalid(out error),
        };
    }

    private static bool? Invalid(out string error)
    {
        error = $"{INCLUDE_BLOCKED} must be true or false";

        return null;
    }

    private static string? Required(Dictionary<string, string> options, string option, out string error)
    {
        if (!options.TryGetValue(key: option, value: out string? value) || string.IsNullOrEmpty(value))
        {
            error = $"{option} is required";

            return null;
        }

        error = string.Empty;

        return value;
    }
}
