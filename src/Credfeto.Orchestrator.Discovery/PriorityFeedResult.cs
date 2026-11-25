using System.Diagnostics;

namespace Credfeto.Orchestrator.Discovery;

// Feed is the URL that was asked, with the user query parameter when there was one. Items is the filtered feed as
// compact JSON, or null when the status is not FETCHED or the feed's body held no JSON value. Problem says why the
// read failed
[DebuggerDisplay("{Status}: {Feed}")]
public sealed record PriorityFeedResult(PriorityFeedStatus Status, string Feed, string? Items, string? Problem);
