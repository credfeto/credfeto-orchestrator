using System.Diagnostics;
using Credfeto.Orchestrator.Discovery;

namespace Credfeto.Orchestrator.Commands;

// Endpoint is the priorities feed or the githubstatus.com summary; User is the login sent with the feed (null for none);
// Retry is for the feed and the collaborators read; TrustedLogins is the trusted-logins request; Rules is for the
// GitHub health gate
[DebuggerDisplay("Read={Read}, Endpoint={Endpoint}")]
public sealed record DiscoveryCommand(
    DiscoveryRead Read,
    string Endpoint,
    string? User,
    RetryPolicy Retry,
    TrustedLoginsRequest? TrustedLogins,
    GitHubHealthRules Rules
);
