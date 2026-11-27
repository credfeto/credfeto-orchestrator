using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.GitHub.Tests;

// Answers every tool call with a fixed result, or fails it with a fixed message, and records the last call, with each
// string argument as its text and any other as its JSON. tools/list gives tools (every tool the reads use when null),
// or fails with toolsError
internal sealed class FakeMcpToolCaller : IMcpToolCaller
{
    public static readonly IReadOnlyList<string> EveryTool =
    [
        "auth_status",
        "branch_compare",
        "branch_required_checks",
        "closing_issue_labels",
        "commit_check_runs",
        "pr_comments",
        "pr_list",
        "pr_view",
        "repo_collaborators",
    ];

    private readonly string? _error;
    private readonly string? _result;
    private readonly IReadOnlyList<string> _tools;
    private readonly string? _toolsError;

    public FakeMcpToolCaller(
        string? result,
        string? error,
        IReadOnlyList<string>? tools = null,
        string? toolsError = null
    )
    {
        this._result = result;
        this._error = error;
        this._tools = tools ?? EveryTool;
        this._toolsError = toolsError;
    }

    public int ToolLists { get; private set; }

    public string? Tool { get; private set; }

    public IReadOnlyDictionary<string, string>? Arguments { get; private set; }

    public ValueTask<string> CallAsync(
        string tool,
        IReadOnlyDictionary<string, JsonElement> arguments,
        CancellationToken cancellationToken
    )
    {
        this.Tool = tool;
        this.Arguments = arguments.ToDictionary(
            keySelector: argument => argument.Key,
            elementSelector: argument =>
                argument.Value.ValueKind == JsonValueKind.String
                    ? argument.Value.GetString() ?? string.Empty
                    : argument.Value.GetRawText(),
            comparer: StringComparer.Ordinal
        );

        if (cancellationToken.IsCancellationRequested)
        {
            return ValueTask.FromCanceled<string>(cancellationToken);
        }

        return this._error is null
            ? ValueTask.FromResult(this._result ?? string.Empty)
            : ValueTask.FromException<string>(new GitHubReadException(this._error));
    }

    public ValueTask<IReadOnlyList<string>> ListToolsAsync(CancellationToken cancellationToken)
    {
        this.ToolLists++;

        if (cancellationToken.IsCancellationRequested)
        {
            return ValueTask.FromCanceled<IReadOnlyList<string>>(cancellationToken);
        }

        return this._toolsError is null
            ? ValueTask.FromResult(this._tools)
            : ValueTask.FromException<IReadOnlyList<string>>(new GitHubReadException(this._toolsError));
    }
}
