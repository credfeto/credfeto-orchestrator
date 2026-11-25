using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Predicates.Tests;

[DebuggerDisplay("{Function}: {Name}")]
public sealed record PredicateParityCase(
    string Name,
    string Function,
    IReadOnlyList<string> Arguments,
    int PerCommentMaximum,
    int Status,
    string Output
);
