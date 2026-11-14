using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Commands.Tests;

// Answers every tool call with a fixed result, or fails it with a fixed message, and records the last call
internal sealed class FakeMcpToolCaller : IMcpToolCaller
{
    private readonly string? _error;
    private readonly string? _result;

    public FakeMcpToolCaller(string? result, string? error)
    {
        this._result = result;
        this._error = error;
    }

    public string? Tool { get; private set; }

    public IReadOnlyDictionary<string, string>? Arguments { get; private set; }

    public ValueTask<string> CallAsync(
        string tool,
        IReadOnlyDictionary<string, string> arguments,
        CancellationToken cancellationToken
    )
    {
        this.Tool = tool;
        this.Arguments = arguments;

        if (cancellationToken.IsCancellationRequested)
        {
            return ValueTask.FromCanceled<string>(cancellationToken);
        }

        return this._error is null
            ? ValueTask.FromResult(this._result ?? string.Empty)
            : ValueTask.FromException<string>(new GitHubReadException(this._error));
    }
}
