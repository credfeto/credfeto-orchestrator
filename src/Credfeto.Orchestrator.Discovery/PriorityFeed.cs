using System;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discovery;

public sealed class PriorityFeed : IPriorityFeed
{
    // fetch_all_priorities' curl --connect-timeout 10 --max-time 60, without --location
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan MaxTime = TimeSpan.FromSeconds(60);

    private readonly IRetryDelay _delay;
    private readonly IUrlReader _urls;

    public PriorityFeed(IUrlReader urls, IRetryDelay delay)
    {
        this._urls = urls;
        this._delay = delay;
    }

    public async ValueTask<PriorityFeedResult> FetchAsync(
        string url,
        string? user,
        RetryPolicy retry,
        CancellationToken cancellationToken
    )
    {
        string requested = WithUser(url: url, user: user);

        if (!Uri.TryCreate(uriString: requested, uriKind: UriKind.Absolute, result: out Uri? uri))
        {
            return new(
                Status: PriorityFeedStatus.UNREACHABLE,
                Feed: requested,
                Items: null,
                Problem: "not an absolute URL"
            );
        }

        string body;

        try
        {
            body = await Retrying.RunAsync<string, UrlReadException>(
                attempt: token =>
                    this._urls.ReadAsync(
                        request: new(
                            Url: uri,
                            FollowRedirects: false,
                            ConnectTimeout: ConnectTimeout,
                            MaxTime: MaxTime
                        ),
                        cancellationToken: token
                    ),
                policy: retry,
                delay: this._delay,
                cancellationToken: cancellationToken
            );
        }
        catch (UrlReadException exception)
        {
            return new(
                Status: PriorityFeedStatus.UNREACHABLE,
                Feed: requested,
                Items: null,
                Problem: exception.Message
            );
        }

        return Parse(url: requested, body: body);
    }

    // The shell appends the parameter to PRIORITIES_URL, which has no query of its own
    public static string WithUser(string url, string? user)
    {
        return string.IsNullOrEmpty(user) ? url : url + "?user=" + UriComponent.Encode(user);
    }

    private static PriorityFeedResult Parse(string url, string body)
    {
        try
        {
            return new(
                Status: PriorityFeedStatus.FETCHED,
                Feed: url,
                Items: PriorityFilter.Filter(body),
                Problem: null
            );
        }
        catch (JqException exception)
        {
            return new(Status: PriorityFeedStatus.UNPARSEABLE, Feed: url, Items: null, Problem: exception.Message);
        }
    }
}
