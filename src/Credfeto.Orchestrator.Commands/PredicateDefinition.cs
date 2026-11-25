using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

[DebuggerDisplay("Kind={Kind}")]
internal sealed record PredicateDefinition(
    PredicateKind Kind,
    IReadOnlyList<string> Options,
    IReadOnlyList<string> Required
);
