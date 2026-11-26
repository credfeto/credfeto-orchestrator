using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.State.Tests;

// A stdin whose writer has gone wrong: every read fails
internal sealed class FailingReadStream : MemoryStream
{
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        return ValueTask.FromException<int>(new IOException("broken pipe"));
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        return Task.FromException<int>(new IOException("broken pipe"));
    }

    public override Task CopyToAsync(Stream destination, int bufferSize, CancellationToken cancellationToken)
    {
        return Task.FromException(new IOException("broken pipe"));
    }
}
