using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Commands.Tests;

// Fails the first failures tool calls, then answers every call with result; records the calls and the last one made,
// with each string argument as its text and any other as its JSON
internal sealed class ScriptedMcpToolCaller : IMcpToolCaller
{
    private readonly int _failures;
    private readonly string _result;

    public ScriptedMcpToolCaller(int failures, string result)
    {
        this._failures = failures;
        this._result = result;
    }

    public int Calls { get; private set; }

    public string? Tool { get; private set; }

    public IReadOnlyDictionary<string, string>? Arguments { get; private set; }

    public ValueTask<string> CallAsync(
        string tool,
        IReadOnlyDictionary<string, JsonElement> arguments,
        CancellationToken cancellationToken
    )
    {
        this.Calls++;
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

        return this.Calls > this._failures
            ? ValueTask.FromResult(this._result)
            : ValueTask.FromException<string>(new GitHubReadException("the server is down"));
    }
}
