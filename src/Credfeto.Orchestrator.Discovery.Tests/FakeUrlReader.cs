using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery.Tests;

// Answers each read with the next body, failing it where the body is null (or none is left), and records every request
internal sealed class FakeUrlReader : IUrlReader
{
    private readonly Queue<string?> _bodies;
    private readonly List<UrlRequest> _requests = [];

    public FakeUrlReader(params IEnumerable<string?> bodies)
    {
        this._bodies = new(bodies);
    }

    public IReadOnlyList<UrlRequest> Requests => this._requests;

    public ValueTask<string> ReadAsync(UrlRequest request, CancellationToken cancellationToken)
    {
        this._requests.Add(request);

        return this._bodies.TryDequeue(out string? body) && body is not null
            ? ValueTask.FromResult(body)
            : ValueTask.FromException<string>(new UrlReadException($"{request.Url} could not be read: refused"));
    }
}
