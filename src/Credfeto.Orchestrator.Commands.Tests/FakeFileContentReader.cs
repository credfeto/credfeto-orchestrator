using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Commands.Tests;

// Serves file content (or a read failure) from memory and records which paths were read
internal sealed class FakeFileContentReader : IFileContentReader
{
    private readonly Dictionary<string, string> _contents = [with(StringComparer.Ordinal)];
    private readonly Dictionary<string, Exception> _failures = [with(StringComparer.Ordinal)];
    private readonly List<string> _read = [];

    public IReadOnlyList<string> Read => this._read;

    public ValueTask<string> ReadAllTextAsync(string path, CancellationToken cancellationToken)
    {
        this._read.Add(path);

        if (this._failures.TryGetValue(key: path, value: out Exception? exception))
        {
            return ValueTask.FromException<string>(exception);
        }

        return this._contents.TryGetValue(key: path, value: out string? content)
            ? ValueTask.FromResult(content)
            : ValueTask.FromException<string>(new FileNotFoundException(message: "Not found", fileName: path));
    }

    public void Add(string path, string content)
    {
        this._contents[path] = content;
    }

    public void Fail(string path, Exception exception)
    {
        this._failures[path] = exception;
    }
}
