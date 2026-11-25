using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Discovery;

// lib/globals' GITHUB_HEALTH_COMPONENTS (the githubstatus.com components a session depends on),
// GITHUB_HEALTH_SERIOUS_IMPACTS and GITHUB_HEALTH_OUTAGE_STATUSES
[DebuggerDisplay("Components={Components.Count}")]
public sealed record GitHubHealthRules(
    IReadOnlyList<string> Components,
    IReadOnlyList<string> SeriousImpacts,
    IReadOnlyList<string> OutageStatuses
)
{
    // The lib/globals values; test/fixtures/discovery-parity.json pins both sides to the same lists
    public static readonly GitHubHealthRules Default = new(
        Components: ["Git Operations", "Pull Requests", "Issues", "API Requests", "Webhooks", "Actions"],
        SeriousImpacts: ["major", "critical"],
        OutageStatuses: ["partial_outage", "major_outage"]
    );
}
