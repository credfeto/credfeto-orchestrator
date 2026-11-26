using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman.Tests;

// A directory of its own for the result files one test writes, removed with it
internal sealed class ResultFiles : IDisposable
{
    public ResultFiles()
    {
        this.Directory = Path.Combine(
            path1: Path.GetTempPath(),
            path2: "claude-result-" + Guid.NewGuid().ToString("N")
        );
        System.IO.Directory.CreateDirectory(this.Directory);
    }

    public string Directory { get; }

    public void Dispose()
    {
        System.IO.Directory.Delete(path: this.Directory, recursive: true);
    }

    public async Task<string> WriteAsync(byte[] content, CancellationToken cancellationToken)
    {
        string path = Path.Combine(path1: this.Directory, path2: "result.json");
        await File.WriteAllBytesAsync(path: path, bytes: content, cancellationToken: cancellationToken);

        return path;
    }
}
