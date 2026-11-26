using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman.Tests;

// A stdin that cannot be read: copying it fails as a read error does
internal sealed class FailingInputStream : MemoryStream
{
    public override Task CopyToAsync(Stream destination, int bufferSize, CancellationToken cancellationToken)
    {
        return Task.FromException(new IOException("stdin could not be read"));
    }
}
