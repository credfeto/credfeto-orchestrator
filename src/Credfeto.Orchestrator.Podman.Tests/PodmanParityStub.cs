using System;
using System.IO;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// The fixture's podman stand-in, written once next to the tests (a temporary directory may not let a script run),
// with a fresh directory for each case's scripted responses
[SupportedOSPlatform("linux")]
public sealed class PodmanParityStub : IAsyncLifetime
{
    private readonly string _root = Path.Combine(
        path1: AppContext.BaseDirectory,
        path2: "podman-parity-" + Guid.NewGuid().ToString("N")
    );

    public string Executable => Path.Combine(path1: this._root, path2: "podman");

    public async ValueTask InitializeAsync()
    {
        Directory.CreateDirectory(this._root);
        string stub = await PodmanParityFixture.StubAsync(CancellationToken.None);
        await File.WriteAllTextAsync(path: this.Executable, contents: stub, cancellationToken: CancellationToken.None);
        File.SetUnixFileMode(
            path: this.Executable,
            mode: UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
        );
    }

    public ValueTask DisposeAsync()
    {
        Directory.Delete(path: this._root, recursive: true);

        return ValueTask.CompletedTask;
    }

    public string NewCaseDirectory()
    {
        return Directory.CreateDirectory(Path.Combine(path1: this._root, path2: Guid.NewGuid().ToString("N"))).FullName;
    }
}
