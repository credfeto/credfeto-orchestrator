using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

public interface IPriorityFeed
{
    // fetch_all_priorities: reads url, with user (when not empty) URL-encoded as the user query parameter, retrying a
    // failed read as retry says, and keeps the open and draft items that are not on hold
    ValueTask<PriorityFeedResult> FetchAsync(
        string url,
        string? user,
        RetryPolicy retry,
        CancellationToken cancellationToken
    );
}
