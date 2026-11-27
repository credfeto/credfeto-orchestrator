using System;
using System.Collections.Generic;
using System.Globalization;
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
    private const string AUTH_STATUS = "auth_status";
    private const string PR_VIEW = "pr_view";
    private const string BRANCH_COMPARE = "branch_compare";
    private const string PR_COMMENTS = "pr_comments";
    private const string CLOSING_ISSUE_LABELS = "closing_issue_labels";
    private const string APP_PREFIX = "app/";
    private const string BOT_SUFFIX = "[bot]";
    private const string REPO_COLLABORATORS = "repo_collaborators";
    private const string COMMIT_CHECK_RUNS = "commit_check_runs";

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
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["head"] = McpArgument.Of(head),
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
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
            },
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

    // The server writes "-" for a pull request GitHub gives no author, where gh gives none, which own_pr_author and the
    // issue stand-off read as an empty login
    private static string Login(string author)
    {
        return StringComparer.Ordinal.Equals(x: author, y: "-") ? string.Empty : author;
    }

    private static bool IsAuthor(string author, string me, string creator)
    {
        string login = Login(author);

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
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["branch"] = McpArgument.Of(branch),
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

    public async ValueTask<string> CurrentLoginAsync(CancellationToken cancellationToken)
    {
        AuthStatusResult result = await this.CallAsync(
            tool: AUTH_STATUS,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal),
            typeInfo: GitHubJsonContext.Default.AuthStatusResult,
            cancellationToken: cancellationToken
        );

        return result.Login ?? throw Unexpected(AUTH_STATUS);
    }

    public async ValueTask<IReadOnlyList<OpenPullRequestReferences>> OpenPullRequestsWithClosingIssuesAsync(
        string repository,
        CancellationToken cancellationToken
    )
    {
        PullRequestListResult result = await this.CallAsync(
            tool: PR_LIST,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["closingIssues"] = McpArgument.Of(true),
            },
            typeInfo: GitHubJsonContext.Default.PullRequestListResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<PullRequestListResultEntry?> entries = result.PullRequests ?? throw Unexpected(PR_LIST);

        return [.. entries.Select(References).OrderByDescending(entry => entry.Number)];
    }

    private static OpenPullRequestReferences References(PullRequestListResultEntry? entry)
    {
        return
            entry is { Number: > 0, Author: not null, Head: not null, ClosingIssues: not null } valid
            && valid.ClosingIssues.All(issue => issue is { Number: > 0 })
            ? new(
                Number: valid.Number,
                Author: Login(valid.Author),
                ClosingIssues: [.. valid.ClosingIssues.OfType<ClosingIssueResult>().Select(issue => issue.Number)],
                Head: valid.Head
            )
            : throw Unexpected(PR_LIST);
    }

    public async ValueTask<IReadOnlyList<PullRequestCommit>> PullRequestCommitsAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    )
    {
        PullRequestViewResult result = await this.PullRequestViewAsync(
            repository: repository,
            pullRequest: pullRequest,
            field: "commits",
            cancellationToken: cancellationToken
        );

        IReadOnlyList<PullRequestViewCommitResult?> commits = result.Commits ?? throw Unexpected(PR_VIEW);

        return [.. commits.Select(Commit)];
    }

    private static PullRequestCommit Commit(PullRequestViewCommitResult? commit)
    {
        return
            commit is { Authors: not null } valid
            && valid.Authors.All(author => author is { Login: not null, Email: not null })
            ? new(
                Authors:
                [
                    .. valid
                        .Authors.OfType<CommitAuthorResult>()
                        .Select(author => new CommitAuthor(
                            Login: author.Login ?? string.Empty,
                            Email: author.Email ?? string.Empty
                        )),
                ]
            )
            : throw Unexpected(PR_VIEW);
    }

    public async ValueTask<int> BranchBehindByAsync(
        string repository,
        string baseBranch,
        string headBranch,
        CancellationToken cancellationToken
    )
    {
        BranchCompareResult result = await this.CallAsync(
            tool: BRANCH_COMPARE,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["base"] = McpArgument.Of(baseBranch),
                ["head"] = McpArgument.Of(headBranch),
            },
            typeInfo: GitHubJsonContext.Default.BranchCompareResult,
            cancellationToken: cancellationToken
        );

        return result.BehindBy is { } behindBy and >= 0 ? behindBy : throw Unexpected(BRANCH_COMPARE);
    }

    public async ValueTask<PullRequestComments> PullRequestCommentsAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    )
    {
        // Exact bodies: GitHub's REST API, which the shell version reads, keeps a body's trailing line breaks
        PullRequestCommentsResult result = await this.CallAsync(
            tool: PR_COMMENTS,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["pr"] = McpArgument.Of(pullRequest),
                ["exactBodies"] = McpArgument.Of(true),
            },
            typeInfo: GitHubJsonContext.Default.PullRequestCommentsResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<PullRequestCommentResult?> comments = result.Comments ?? throw Unexpected(PR_COMMENTS);
        IReadOnlyList<PullRequestThreadResult?> threads = result.Threads ?? throw Unexpected(PR_COMMENTS);

        // The server groups inline comments by thread; the REST listing the shell version reads is in id order
        return new(
            Comments: [.. comments.Select(TopLevelComment).OrderBy(comment => comment.Id)],
            ReviewComments: [.. threads.SelectMany(ReviewComments).OrderBy(comment => comment.Id)]
        );
    }

    private static PullRequestComment TopLevelComment(PullRequestCommentResult? comment)
    {
        return
            comment is { Author: not null, Body: not null, CreatedAt: not null, UpdatedAt: not null } valid
            && CommentId(valid.Id) is { } id
            ? new(
                Id: id,
                Login: RestLogin(valid.Author),
                Body: valid.Body,
                CreatedAt: valid.CreatedAt,
                UpdatedAt: valid.UpdatedAt
            )
            : throw Unexpected(PR_COMMENTS);
    }

    private static IEnumerable<PullRequestReviewComment> ReviewComments(PullRequestThreadResult? thread)
    {
        return thread is { Path: not null, Comments: not null } valid
            ? valid.Comments.Select(comment => ReviewComment(path: valid.Path, comment: comment))
            : throw Unexpected(PR_COMMENTS);
    }

    private static PullRequestReviewComment ReviewComment(string path, PullRequestCommentResult? comment)
    {
        return
            comment is { Author: not null, Body: not null, UpdatedAt: not null } valid && CommentId(valid.Id) is { } id
            ? new(Id: id, Login: RestLogin(valid.Author), Path: path, Body: valid.Body, UpdatedAt: valid.UpdatedAt)
            : throw Unexpected(PR_COMMENTS);
    }

    private static long? CommentId(string? id)
    {
        return
            !string.IsNullOrEmpty(id)
            && long.TryParse(
                s: id,
                style: NumberStyles.None,
                provider: CultureInfo.InvariantCulture,
                result: out long value
            )
            && value > 0
            ? value
            : null;
    }

    // The login as GitHub's REST API gives it: a GitHub App's bot account is "<slug>[bot]" there, another kind of
    // account its bare login, and a deleted account has none
    private static string? RestLogin(string author)
    {
        if (author.Length == 0)
        {
            return null;
        }

        if (author.StartsWith(value: APP_PREFIX, comparisonType: StringComparison.Ordinal))
        {
            return author[APP_PREFIX.Length..] + BOT_SUFFIX;
        }

        int kind = author.IndexOf('/', StringComparison.Ordinal);

        return kind < 0 ? author : author[(kind + 1)..];
    }

    public async ValueTask<IReadOnlyList<int>> PullRequestClosingIssuesAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    )
    {
        PullRequestViewResult result = await this.PullRequestViewAsync(
            repository: repository,
            pullRequest: pullRequest,
            field: "closing-issues",
            cancellationToken: cancellationToken
        );

        IReadOnlyList<ClosingIssueResult?> issues = result.ClosingIssues ?? throw Unexpected(PR_VIEW);

        return [.. issues.Select(issue => issue is { Number: > 0 } valid ? valid.Number : throw Unexpected(PR_VIEW))];
    }

    public async ValueTask<IReadOnlyList<string>> ClosingIssueLabelsAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    )
    {
        ClosingIssueLabelsResult result = await this.CallAsync(
            tool: CLOSING_ISSUE_LABELS,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["pr"] = McpArgument.Of(pullRequest),
            },
            typeInfo: GitHubJsonContext.Default.ClosingIssueLabelsResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<string?> labels = result.Labels ?? throw Unexpected(CLOSING_ISSUE_LABELS);

        return
        [
            .. labels.Select(label => string.IsNullOrEmpty(label) ? throw Unexpected(CLOSING_ISSUE_LABELS) : label),
        ];
    }

    // pr_view asked for the one opt-in field a read uses
    private ValueTask<PullRequestViewResult> PullRequestViewAsync(
        string repository,
        int pullRequest,
        string field,
        CancellationToken cancellationToken
    )
    {
        return this.CallAsync(
            tool: PR_VIEW,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["pr"] = McpArgument.Of(pullRequest),
                ["fields"] = McpArgument.Of([field]),
            },
            typeInfo: GitHubJsonContext.Default.PullRequestViewResult,
            cancellationToken: cancellationToken
        );
    }

    public async ValueTask<IReadOnlyList<string>> RepositoryCollaboratorsAsync(
        string repository,
        CancellationToken cancellationToken
    )
    {
        RepositoryCollaboratorsResult result = await this.CallAsync(
            tool: REPO_COLLABORATORS,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
            },
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

    public async ValueTask<IReadOnlyList<PullRequestCheck>> PullRequestChecksAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    )
    {
        // Exact names: the GraphQL rollup the shell version reads keeps a name's line breaks and spaces
        PullRequestViewResult result = await this.CallAsync(
            tool: PR_VIEW,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["pr"] = McpArgument.Of(pullRequest),
                ["fields"] = McpArgument.Of(["checks"]),
                ["exactCheckNames"] = McpArgument.Of(true),
            },
            typeInfo: GitHubJsonContext.Default.PullRequestViewResult,
            cancellationToken: cancellationToken
        );

        IReadOnlyList<PullRequestCheckResult?> checks = result.Checks ?? throw Unexpected(PR_VIEW);

        return [.. checks.Select(Check)];
    }

    // A server older than workflow-mcp #188 lists the checks without GitHub's required flag
    private static PullRequestCheck Check(PullRequestCheckResult? check)
    {
        return check switch
        {
            { Name: { } name, Required: { } required } => new(Name: name, Required: required),
            { Name: not null } => throw new McpServerOutdatedException(
                $"the cfwf MCP server's {PR_VIEW} checks carry no required flag"
            ),
            _ => throw Unexpected(PR_VIEW),
        };
    }

    public async ValueTask<int> CommitRunningCheckRunsAsync(
        string repository,
        string sha,
        CancellationToken cancellationToken
    )
    {
        IReadOnlyList<string> tools = await this._tools.ListToolsAsync(cancellationToken);

        if (!tools.Contains(value: COMMIT_CHECK_RUNS, comparer: StringComparer.Ordinal))
        {
            throw new McpServerOutdatedException($"the cfwf MCP server does not list {COMMIT_CHECK_RUNS}");
        }

        CommitCheckRunsResult result = await this.CallAsync(
            tool: COMMIT_CHECK_RUNS,
            arguments: new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["repo"] = McpArgument.Of(repository),
                ["sha"] = McpArgument.Of(sha),
            },
            typeInfo: GitHubJsonContext.Default.CommitCheckRunsResult,
            cancellationToken: cancellationToken
        );

        return result.Running is { } running and >= 0 ? running : throw Unexpected(COMMIT_CHECK_RUNS);
    }

    private async ValueTask<T> CallAsync<T>(
        string tool,
        IReadOnlyDictionary<string, JsonElement> arguments,
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
