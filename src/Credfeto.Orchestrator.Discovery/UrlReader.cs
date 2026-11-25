using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

// What the shell's curl --silent --fail does for the URLs oneshot reads: an https or http GET, or a file:// read (the
// tests point GITHUB_STATUS_URL at a fixture file). An HTTP status of 400 or above fails, as --fail makes it; anything
// below it is the body, a redirect that was not followed included, as curl prints it
public sealed class UrlReader : IUrlReader
{
    private const int FIRST_HTTP_ERROR = 400;

    private static readonly Encoding Utf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    private readonly Func<UrlRequest, HttpMessageHandler> _handlers;

    public UrlReader()
        : this(CreateHandler) { }

    public UrlReader(Func<UrlRequest, HttpMessageHandler> handlers)
    {
        this._handlers = handlers;
    }

    // One handler a request, since redirects and the connect timeout are a handler's settings; the tool makes one read
    // a run, so nothing is lost by not pooling connections
    public static HttpMessageHandler CreateHandler(UrlRequest request)
    {
        return new SocketsHttpHandler
        {
            AllowAutoRedirect = request.FollowRedirects,
            ConnectTimeout = request.ConnectTimeout,
        };
    }

    public async ValueTask<string> ReadAsync(UrlRequest request, CancellationToken cancellationToken)
    {
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(request.MaxTime);

        try
        {
            byte[] body = request.Url.IsFile
                ? await File.ReadAllBytesAsync(path: request.Url.LocalPath, cancellationToken: timeout.Token)
                : await this.GetAsync(request: request, cancellationToken: timeout.Token);

            return Utf8.GetString(body);
        }
        catch (Exception exception) when (IsReadFailure(exception: exception, cancellationToken: cancellationToken))
        {
            throw new UrlReadException(
                message: $"{request.Url} could not be read: {exception.Message}",
                innerException: exception
            );
        }
    }

    private async ValueTask<byte[]> GetAsync(UrlRequest request, CancellationToken cancellationToken)
    {
        if (!IsHttp(request.Url))
        {
            throw new UrlReadException($"{request.Url} is not an http, https or file URL");
        }

        using HttpClient client = new(handler: this._handlers(request), disposeHandler: true);
        client.Timeout = Timeout.InfiniteTimeSpan;

        using HttpResponseMessage response = await client.GetAsync(
            requestUri: request.Url,
            completionOption: HttpCompletionOption.ResponseContentRead,
            cancellationToken: cancellationToken
        );

        int status = (int)response.StatusCode;

        return status >= FIRST_HTTP_ERROR
            ? throw new UrlReadException($"{request.Url} could not be read: HTTP {status}")
            : await response.Content.ReadAsByteArrayAsync(cancellationToken);
    }

    private static bool IsHttp(Uri url)
    {
        return StringComparer.Ordinal.Equals(x: url.Scheme, y: Uri.UriSchemeHttps)
            || StringComparer.Ordinal.Equals(x: url.Scheme, y: Uri.UriSchemeHttp);
    }

    // A cancelled run is left to propagate; the --max-time timeout is a failed read, as it is for curl
    private static bool IsReadFailure(Exception exception, CancellationToken cancellationToken)
    {
        return exception switch
        {
            OperationCanceledException => !cancellationToken.IsCancellationRequested,
            HttpRequestException or IOException or UnauthorizedAccessException => true,
            _ => false,
        };
    }
}
