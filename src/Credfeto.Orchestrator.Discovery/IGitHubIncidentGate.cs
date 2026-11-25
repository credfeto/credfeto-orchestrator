using System;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

public interface IGitHubIncidentGate
{
    // github_incident_open: reads the githubstatus.com summary at url and judges its unresolved incidents by rules.
    // Never throws for a status that cannot be read: that is GitHubIncidentKind.UNREADABLE, so the gate fails open
    ValueTask<GitHubIncident> CheckAsync(Uri url, GitHubHealthRules rules, CancellationToken cancellationToken);
}
