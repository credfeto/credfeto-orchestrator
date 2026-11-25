namespace Credfeto.Orchestrator.Discovery;

public enum PriorityFeedStatus
{
    // fetch_all_priorities returns 0
    FETCHED,

    // fetch_all_priorities returns 1: every attempt failed to read the feed
    UNREACHABLE,

    // fetch_all_priorities returns 2: the feed answered, but not with the expected JSON
    UNPARSEABLE,
}
