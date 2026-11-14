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
