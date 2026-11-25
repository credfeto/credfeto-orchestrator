using System.Diagnostics;

namespace Credfeto.Orchestrator.Discovery;

// Line is what github_incident_open prints: "<name><TAB><created_at>" for a serious incident and
// "<name><TAB><created_at><TAB><component>: <status>" for a minor one, empty otherwise. Problem says why the status
// could not be read
[DebuggerDisplay("{Kind}: {Line}")]
public sealed record GitHubIncident(GitHubIncidentKind Kind, string Line, string? Problem = null);
