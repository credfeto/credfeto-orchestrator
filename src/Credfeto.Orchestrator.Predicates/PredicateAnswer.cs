using System.Diagnostics;

namespace Credfeto.Orchestrator.Predicates;

// A predicate's answer, as `jq -e` gives it: Holds when the program's last output is true; Problem
// says why jq would have failed, which the shell reads as false too
[DebuggerDisplay("Holds={Holds}, Problem={Problem}")]
public sealed record PredicateAnswer(bool Holds, string? Problem);
