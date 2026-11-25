using System;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Discovery;

// One curl GET: FollowRedirects is curl's --location, ConnectTimeout its --connect-timeout and MaxTime its --max-time
[DebuggerDisplay("{Url}")]
public sealed record UrlRequest(Uri Url, bool FollowRedirects, TimeSpan ConnectTimeout, TimeSpan MaxTime);
