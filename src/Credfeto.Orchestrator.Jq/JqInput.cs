using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Jq;

[DebuggerDisplay("Values={Values.Count}, Complete={Complete}")]
public sealed record JqInput(IReadOnlyList<JqValue> Values, bool Complete);
