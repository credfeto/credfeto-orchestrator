using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman.Tests;

// A test/fixtures file embedded in this assembly under its file name
internal static class EmbeddedFixture
{
    public static async Task<JsonDocument> LoadAsync(string resourceName, CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(EmbeddedFixture).Assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException("Missing embedded resource " + resourceName);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
