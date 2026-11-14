using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

[DebuggerDisplay("#{Number}")]
internal sealed record PullRequestListResultEntry(int Number);
