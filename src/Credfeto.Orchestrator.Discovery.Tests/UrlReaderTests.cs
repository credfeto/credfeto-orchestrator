using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class UrlReaderTests : TestBase
{
    private static readonly Uri Feed = new("https://feed.example/priorities?user=me");

    [Fact]
    public async Task AnHttpBodyIsReturnedFromAHandlerMadeForTheRequestAsync()
    {
        using FakeHttpHandler handler = Answering(status: HttpStatusCode.OK, body: "{\"ok\":true}"u8.ToArray());
        UrlRequest? made = null;
        UrlReader reader = new(request =>
        {
            made = request;

            return handler;
        });
        UrlRequest request = Request(Feed);

        string body = await reader.ReadAsync(request: request, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: "{\"ok\":true}", actual: body);
        Assert.Same(expected: request, actual: made);
        Assert.Equal(expected: Feed, actual: handler.RequestUri);
    }

    [Theory]
    [InlineData(HttpStatusCode.MovedPermanently)]
    [InlineData((HttpStatusCode)399)]
    public async Task AStatusBelowFourHundredIsTheBodyAsCurlFailPrintsItAsync(HttpStatusCode status)
    {
        using FakeHttpHandler handler = Answering(status: status, body: "moved"u8.ToArray());

        string body = await new UrlReader(_ => handler).ReadAsync(
            request: Request(Feed),
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: "moved", actual: body);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.NotFound)]
    [InlineData(HttpStatusCode.BadGateway)]
    public async Task AnHttpErrorFailsAsCurlFailMakesItAsync(HttpStatusCode status)
    {
        using FakeHttpHandler handler = Answering(status: status, body: "error page"u8.ToArray());

        UrlReadException exception = await Assert.ThrowsAsync<UrlReadException>(() =>
            new UrlReader(_ => handler)
                .ReadAsync(request: Request(Feed), cancellationToken: this.CancellationToken())
                .AsTask()
        );

        Assert.Equal(expected: $"{Feed} could not be read: HTTP {(int)status}", actual: exception.Message);
    }

    [Fact]
    public async Task AConnectionFailureFailsAsync()
    {
        using FakeHttpHandler handler = new((_, _) => throw new HttpRequestException("connection refused"));

        UrlReadException exception = await Assert.ThrowsAsync<UrlReadException>(() =>
            new UrlReader(_ => handler)
                .ReadAsync(request: Request(Feed), cancellationToken: this.CancellationToken())
                .AsTask()
        );

        Assert.Equal(expected: $"{Feed} could not be read: connection refused", actual: exception.Message);
    }

    [Fact]
    public async Task AReadThatTakesLongerThanTheMaximumTimeFailsAsync()
    {
        using FakeHttpHandler handler = new(
            async (_, token) =>
            {
                await Task.Delay(delay: Timeout.InfiniteTimeSpan, cancellationToken: token);

                return new(HttpStatusCode.OK);
            }
        );

        await Assert.ThrowsAsync<UrlReadException>(() =>
            new UrlReader(_ => handler)
                .ReadAsync(
                    request: Request(Feed) with
                    {
                        MaxTime = TimeSpan.FromMilliseconds(50),
                    },
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );
    }

    [Fact]
    public async Task ACancelledReadIsLeftToPropagateAsync()
    {
        using FakeHttpHandler handler = Answering(status: HttpStatusCode.OK, body: []);
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new UrlReader(_ => handler).ReadAsync(request: Request(Feed), cancellationToken: cancelled.Token).AsTask()
        );
    }

    [Fact]
    public async Task InvalidUtf8IsReplacedAsJqReadsItAsync()
    {
        using FakeHttpHandler handler = Answering(status: HttpStatusCode.OK, body: [0x61, 0xFF, 0x62]);

        string body = await new UrlReader(_ => handler).ReadAsync(
            request: Request(Feed),
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: "a�b", actual: body);
    }

    [Fact]
    public async Task AFileUrlIsReadFromTheFileAsync()
    {
        string path = Path.Combine(Path.GetTempPath(), $"url-reader-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(
            path: path,
            contents: "{\"incidents\":[]}",
            cancellationToken: this.CancellationToken()
        );

        try
        {
            string body = await new UrlReader().ReadAsync(
                request: Request(new(path)),
                cancellationToken: this.CancellationToken()
            );

            Assert.Equal(expected: "{\"incidents\":[]}", actual: body);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public Task AMissingFileFailsAsync()
    {
        Uri missing = new(Path.Combine(Path.GetTempPath(), $"url-reader-{Guid.NewGuid():N}.json"));

        return Assert.ThrowsAsync<UrlReadException>(() =>
            new UrlReader().ReadAsync(request: Request(missing), cancellationToken: this.CancellationToken()).AsTask()
        );
    }

    [Fact]
    public async Task AUrlThatIsNotHttpOrAFileFailsWithoutARequestAsync()
    {
        Uri ftp = new("ftp://feed.example/priorities");

        UrlReadException exception = await Assert.ThrowsAsync<UrlReadException>(() =>
            new UrlReader(_ => throw new InvalidOperationException("no handler expected"))
                .ReadAsync(request: Request(ftp), cancellationToken: this.CancellationToken())
                .AsTask()
        );

        Assert.Equal(expected: $"{ftp} is not an http, https or file URL", actual: exception.Message);
    }

    [Theory]
    [InlineData(true, 5)]
    [InlineData(false, 10)]
    public static void TheHandlerFollowsRedirectsAndTimesOutConnectingAsAsked(bool followRedirects, int connectSeconds)
    {
        using HttpMessageHandler handler = UrlReader.CreateHandler(
            Request(Feed) with
            {
                FollowRedirects = followRedirects,
                ConnectTimeout = TimeSpan.FromSeconds(connectSeconds),
            }
        );

        SocketsHttpHandler sockets = Assert.IsType<SocketsHttpHandler>(handler);
        Assert.Equal(expected: followRedirects, actual: sockets.AllowAutoRedirect);
        Assert.Equal(expected: TimeSpan.FromSeconds(connectSeconds), actual: sockets.ConnectTimeout);
    }

    private static UrlRequest Request(Uri url)
    {
        return new(
            Url: url,
            FollowRedirects: false,
            ConnectTimeout: TimeSpan.FromSeconds(10),
            MaxTime: TimeSpan.FromSeconds(60)
        );
    }

    private static FakeHttpHandler Answering(HttpStatusCode status, byte[] body)
    {
        return new((_, _) => Task.FromResult(new HttpResponseMessage(status) { Content = new ByteArrayContent(body) }));
    }
}
