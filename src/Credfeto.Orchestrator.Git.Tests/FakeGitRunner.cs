using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Git.Tests;

// Answers each git command line (its arguments joined by spaces) from a script, and records the command lines it ran
internal sealed class FakeGitRunner : IGitRunner
{
    private readonly Dictionary<string, GitResult> _results = [with(StringComparer.Ordinal)];
    private readonly List<string> _ran = [];

    public IReadOnlyList<string> Ran => this._ran;

    public string Repository { get; private set; } = string.Empty;

    public ValueTask<GitResult> RunAsync(
        string repository,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken
    )
    {
        string command = string.Join(separator: ' ', values: arguments);
        this.Repository = repository;
        this._ran.Add(command);

        return this._results.TryGetValue(key: command, value: out GitResult? result)
            ? ValueTask.FromResult(result)
            : ValueTask.FromResult(new GitResult(ExitCode: 128, Output: ReadOnlyMemory<byte>.Empty));
    }

    public FakeGitRunner Returns(string command, int exitCode, string output)
    {
        return this.Returns(command: command, exitCode: exitCode, output: Encoding.UTF8.GetBytes(output));
    }

    public FakeGitRunner Returns(string command, int exitCode, byte[] output)
    {
        this._results[command] = new(ExitCode: exitCode, Output: output);

        return this;
    }
}
