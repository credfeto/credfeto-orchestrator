using System.Diagnostics;

namespace Credfeto.Orchestrator.Predicates;

// What a lib/github-status function prints, and whether it returns 0; Problem says why it failed,
// when that was a jq error
[DebuggerDisplay("Succeeded={Succeeded}, Printed={Printed}, Problem={Problem}")]
public sealed record PredicateOutput(bool Succeeded, string Printed, string? Problem);
