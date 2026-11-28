using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// One check run or status context on a pull request's head commit: its name (a status context's context) exactly as
// GitHub reports it, and whether GitHub requires it for merging this pull request
[DebuggerDisplay("{Name}: Required={Required}")]
public sealed record PullRequestCheck(string Name, bool Required);
