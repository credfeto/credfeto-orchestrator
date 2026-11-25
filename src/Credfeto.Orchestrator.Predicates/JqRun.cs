using System.Collections.Generic;
using System.Diagnostics;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// What a jq program printed over its whole input (Outputs), the first error it hit (Problem), and the
// exit status jq would give: Succeeded is a plain run's status 0, Holds is jq -e's status 0
[DebuggerDisplay("Outputs={Outputs.Count}, Succeeded={Succeeded}, Holds={Holds}, Problem={Problem}")]
internal sealed record JqRun(IReadOnlyList<JqValue> Outputs, string? Problem, bool Succeeded, bool Holds);
