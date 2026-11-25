using System;
using System.IO;

namespace Credfeto.Orchestrator.Agents.Tests;

// A fresh directory under the temporary directory, short enough for socket paths, removed on dispose
internal sealed class TestDirectory : IDisposable
{
    public TestDirectory()
    {
        this.Path = Directory.CreateTempSubdirectory("agents-").FullName;
    }

    public string Path { get; }

    public void Dispose()
    {
        Directory.Delete(path: this.Path, recursive: true);
    }
}
