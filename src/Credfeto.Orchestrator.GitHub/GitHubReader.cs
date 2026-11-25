using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.GitHub;

public sealed class GitHubReader : IGitHubReader
{
    private const string PR_LIST = "pr_list";
    private const string BRANCH_REQUIRED_CHECKS = "branch_required_checks";
    private const string REPO_COLLABORATORS = "repo_collaborators";

    private readonly IMcpToolCaller _tools;

    public GitHubReader(IMcpToolCaller tools)
    {
        this._tools = tools;
    }

    public async ValueTask<IReadOnlyList<int>> OpenPullRequestsOnHeadAsync(
        string repository,
        string head,
        CancellationToken cancellationToken
    )
    {
        PullRequestListResult result = await this.CallAsync(
            tool: PR_LIST,
            arguments: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = repository,
                ["head"] = head,
            },
            typeInfo: GitHubJsonContext.Default.PullRequestListResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<PullRequestListResultEntry?> entries = result.PullRequests ?? throw Unexpected(PR_LIST);

        // The server lists by number, oldest first; gh pr list, which the shell version reads, lists newest first
        return
        [
            .. entries
                .Select(entry => entry is { Number: > 0 } valid ? valid.Number : throw Unexpected(PR_LIST))
                .OrderDescending(),
        ];
    }

    public async ValueTask<IReadOnlyList<int>> OwnOpenPullRequestsAsync(
        string repository,
        string me,
        string creator,
        bool includeBlocked,
        CancellationToken cancellationToken
    )
    {
        PullRequestListResult result = await this.CallAsync(
            tool: PR_LIST,
            arguments: new Dictionary<string, string>(StringComparer.Ordinal) { ["repo"] = repository },
            typeInfo: GitHubJsonContext.Default.PullRequestListResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<PullRequestListResultEntry?> entries = result.PullRequests ?? throw Unexpected(PR_LIST);

        return
        [
            .. entries
                .Select(Own)
                .Where(entry =>
                    IsAuthor(author: entry.Author, me: me, creator: creator)
                    && (includeBlocked || !IsBlocked(entry.Labels))
                )
                .Select(entry => entry.Number)
                .OrderDescending(),
        ];
    }

    // Every entry is checked, not only those the filter keeps, so a list in another shape always fails the read
    private static OwnPullRequest Own(PullRequestListResultEntry? entry)
    {
        return
            entry is { Number: > 0, Author: not null, Labels: not null } valid
            && valid.Labels.All(label => label is not null)
            ? new(Number: valid.Number, Author: valid.Author, Labels: [.. valid.Labels.OfType<string>()])
            : throw Unexpected(PR_LIST);
    }

    // The server writes "-" for a pull request GitHub gives no author, where gh gives none, which own_pr_author reads
    // as an empty login
    private static bool IsAuthor(string author, string me, string creator)
    {
        string login = StringComparer.Ordinal.Equals(x: author, y: "-") ? string.Empty : author;

        return StringComparer.OrdinalIgnoreCase.Equals(x: login, y: me)
            || StringComparer.OrdinalIgnoreCase.Equals(x: login, y: creator);
    }

    private static bool IsBlocked(IReadOnlyList<string> labels)
    {
        return labels.Any(label => StringComparer.OrdinalIgnoreCase.Equals(x: label, y: "blocked"));
    }

    public async ValueTask<bool> BranchRequiresStatusChecksAsync(
        string repository,
        string branch,
        CancellationToken cancellationToken
    )
    {
        BranchRequiredChecksResult result = await this.CallAsync(
            tool: BRANCH_REQUIRED_CHECKS,
            arguments: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = repository,
                ["branch"] = branch,
            },
            typeInfo: GitHubJsonContext.Default.BranchRequiredChecksResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<string?> checks = result.Checks ?? throw Unexpected(BRANCH_REQUIRED_CHECKS);

        return checks.Count switch
        {
            0 => false,
            _ when checks.All(check => !string.IsNullOrEmpty(check)) => true,
            _ => throw Unexpected(BRANCH_REQUIRED_CHECKS),
        };
    }

    public async ValueTask<IReadOnlyList<string>> RepositoryCollaboratorsAsync(
        string repository,
        CancellationToken cancellationToken
    )
    {
        RepositoryCollaboratorsResult result = await this.CallAsync(
            tool: REPO_COLLABORATORS,
            arguments: new Dictionary<string, string>(StringComparer.Ordinal) { ["repo"] = repository },
            typeInfo: GitHubJsonContext.Default.RepositoryCollaboratorsResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<RepositoryCollaboratorsResultEntry?> entries = result.Collaborators
            ?? throw Unexpected(REPO_COLLABORATORS);

        return
        [
            .. entries.Select(entry =>
                entry is { Login.Length: > 0 } valid ? valid.Login : throw Unexpected(REPO_COLLABORATORS)
            ),
        ];
    }

    private async ValueTask<T> CallAsync<T>(
        string tool,
        IReadOnlyDictionary<string, string> arguments,
        JsonTypeInfo<T> typeInfo,
        CancellationToken cancellationToken
    )
        where T : class
    {
        string json = await this._tools.CallAsync(
            tool: tool,
            arguments: arguments,
            cancellationToken: cancellationToken
        );

        try
        {
            return JsonSerializer.Deserialize(json: json, jsonTypeInfo: typeInfo) ?? throw Unexpected(tool);
        }
        catch (JsonException exception)
        {
            throw new GitHubReadException(
                message: $"the cfwf MCP server's {tool} result is not valid JSON",
                innerException: exception
            );
        }
    }

    private static GitHubReadException Unexpected(string tool)
    {
        return new($"the cfwf MCP server's {tool} result is not in the expected shape");
    }
}
