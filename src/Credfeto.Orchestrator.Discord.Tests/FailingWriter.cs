using System;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discord.Tests;

// A stdout whose reader has gone: every write fails as a closed pipe does
internal sealed class FailingWriter : StringWriter
{
    public FailingWriter()
        : base(CultureInfo.InvariantCulture) { }

    public override Task WriteAsync(ReadOnlyMemory<char> buffer, CancellationToken cancellationToken = default)
    {
        return Task.FromException(new IOException("broken pipe"));
    }
}
