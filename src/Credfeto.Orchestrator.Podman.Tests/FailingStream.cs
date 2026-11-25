using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman.Tests;

// A stdout whose reader has gone: every write fails as a closed pipe does
internal sealed class FailingStream : MemoryStream
{
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        return ValueTask.FromException(new IOException("broken pipe"));
    }
}
