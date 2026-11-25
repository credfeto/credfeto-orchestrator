using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman.Tests;

// Answers each podman command line (its arguments joined by spaces) from a script, and records the command lines it ran
internal sealed class FakePodmanRunner : IPodmanRunner
{
    private readonly Dictionary<string, PodmanResult> _results = [with(StringComparer.Ordinal)];
    private readonly List<string> _ran = [];

    public IReadOnlyList<string> Ran => this._ran;

    // Thrown by every run, when set, as PodmanProcessRunner throws when podman cannot be started
    public Exception? Failure { get; set; }

    public ValueTask<PodmanResult> RunAsync(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        string command = string.Join(separator: ' ', values: arguments);
        this._ran.Add(command);

        if (this.Failure is not null)
        {
            return ValueTask.FromException<PodmanResult>(this.Failure);
        }

        return this._results.TryGetValue(key: command, value: out PodmanResult? result)
            ? ValueTask.FromResult(result)
            : ValueTask.FromResult(new PodmanResult(ExitCode: 125, Output: ReadOnlyMemory<byte>.Empty));
    }

    public FakePodmanRunner Returns(string command, int exitCode, string output)
    {
        return this.Returns(command: command, exitCode: exitCode, output: Encoding.UTF8.GetBytes(output));
    }

    public FakePodmanRunner Returns(string command, int exitCode, ReadOnlyMemory<byte> output)
    {
        this._results[command] = new(ExitCode: exitCode, Output: output);

        return this;
    }
}
