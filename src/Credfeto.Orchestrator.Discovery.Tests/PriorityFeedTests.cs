using System;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class PriorityFeedTests : TestBase
{
    private const string FEED = "https://priorities.example/priorities";
    private const string EMPTY = """{"priorities":[]}""";

    private static readonly RetryPolicy ThreeAttempts = new(Attempts: 3, Delay: TimeSpan.FromSeconds(2));

    [Fact]
    public async Task TheFeedIsReadOnceWithTheLoginAndCurlsTimeoutsAsync()
    {
        FakeUrlReader urls = new(EMPTY);
        FakeRetryDelay delay = new();

        PriorityFeedResult result = await FetchAsync(
            urls: urls,
            delay: delay,
            user: "a b",
            retry: ThreeAttempts,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: PriorityFeedStatus.FETCHED, actual: result.Status);
        Assert.Equal(expected: "[]", actual: result.Items);
        Assert.Equal(expected: FEED + "?user=a%20b", actual: result.Feed);
        UrlRequest request = Assert.Single(urls.Requests);
        Assert.Equal(
            expected: new(
                Url: new(FEED + "?user=a%20b"),
                FollowRedirects: false,
                ConnectTimeout: TimeSpan.FromSeconds(10),
                MaxTime: TimeSpan.FromSeconds(60)
            ),
            actual: request
        );
        Assert.Empty(delay.Delays);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public async Task NoLoginSendsNoUserParameterAsync(string? user)
    {
        FakeUrlReader urls = new(EMPTY);

        PriorityFeedResult result = await FetchAsync(
            urls: urls,
            delay: new(),
            user: user,
            retry: ThreeAttempts,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: FEED, actual: result.Feed);
        Assert.Equal(expected: new Uri(FEED), actual: Assert.Single(urls.Requests).Url);
    }

    [Fact]
    public async Task AFailedReadIsRetriedAfterTheDelayAsync()
    {
        FakeUrlReader urls = new(null, null, EMPTY);
        FakeRetryDelay delay = new();

        PriorityFeedResult result = await FetchAsync(
            urls: urls,
            delay: delay,
            user: "me",
            retry: ThreeAttempts,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: PriorityFeedStatus.FETCHED, actual: result.Status);
        Assert.Equal(expected: 3, actual: urls.Requests.Count);
        Assert.Equal(expected: [TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2)], actual: delay.Delays);
    }

    [Fact]
    public async Task AFeedThatIsNeverReadIsUnreachableWithNoDelayAfterTheLastAttemptAsync()
    {
        FakeUrlReader urls = new(null, null, null, EMPTY);
        FakeRetryDelay delay = new();

        PriorityFeedResult result = await FetchAsync(
            urls: urls,
            delay: delay,
            user: "me",
            retry: ThreeAttempts,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: PriorityFeedStatus.UNREACHABLE, actual: result.Status);
        Assert.Null(result.Items);
        Assert.Equal(expected: FEED + "?user=me could not be read: refused", actual: result.Problem);
        Assert.Equal(expected: 3, actual: urls.Requests.Count);
        Assert.Equal(expected: 2, actual: delay.Delays.Count);
    }

    [Fact]
    public async Task AZeroDelayDoesNotSleepAsync()
    {
        FakeUrlReader urls = new(null, EMPTY);
        FakeRetryDelay delay = new();

        await FetchAsync(
            urls: urls,
            delay: delay,
            user: "me",
            retry: new(Attempts: 2, Delay: TimeSpan.Zero),
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 2, actual: urls.Requests.Count);
        Assert.Empty(delay.Delays);
    }

    [Fact]
    public async Task ABodyThatIsNotTheExpectedJsonIsUnparseableAndNotRetriedAsync()
    {
        FakeUrlReader urls = new("<html/>", EMPTY);

        PriorityFeedResult result = await FetchAsync(
            urls: urls,
            delay: new(),
            user: "me",
            retry: ThreeAttempts,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: PriorityFeedStatus.UNPARSEABLE, actual: result.Status);
        Assert.Null(result.Items);
        Assert.NotNull(result.Problem);
        Assert.Single(urls.Requests);
    }

    [Fact]
    public async Task AUrlThatIsNotAbsoluteIsUnreachableWithoutAReadAsync()
    {
        FakeUrlReader urls = new(EMPTY);

        PriorityFeedResult result = await new PriorityFeed(urls: urls, delay: new FakeRetryDelay()).FetchAsync(
            url: "priorities",
            user: null,
            retry: ThreeAttempts,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: PriorityFeedStatus.UNREACHABLE, actual: result.Status);
        Assert.Equal(expected: "not an absolute URL", actual: result.Problem);
        Assert.Empty(urls.Requests);
    }

    private static ValueTask<PriorityFeedResult> FetchAsync(
        FakeUrlReader urls,
        FakeRetryDelay delay,
        string? user,
        RetryPolicy retry,
        CancellationToken cancellationToken
    )
    {
        return new PriorityFeed(urls: urls, delay: delay).FetchAsync(
            url: FEED,
            user: user,
            retry: retry,
            cancellationToken: cancellationToken
        );
    }
}
