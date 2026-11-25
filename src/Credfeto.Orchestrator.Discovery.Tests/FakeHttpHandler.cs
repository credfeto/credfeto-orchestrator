using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery.Tests;

// Answers every request with respond's response, and records the last request's URL
internal sealed class FakeHttpHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> _respond;

    public FakeHttpHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond)
    {
        this._respond = respond;
    }

    public Uri? RequestUri { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken
    )
    {
        this.RequestUri = request.RequestUri;

        return this._respond(request, cancellationToken);
    }
}
