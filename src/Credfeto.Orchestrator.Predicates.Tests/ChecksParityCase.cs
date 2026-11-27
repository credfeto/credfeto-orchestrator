using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Predicates.Tests;

// Refused: the tool must refuse the case (exit 3) rather than answer it, as bash's answer could depend on the locale
[DebuggerDisplay("{Function}: {Name}")]
public sealed record ChecksParityCase(
    string Name,
    string Function,
    IReadOnlyList<string> Arguments,
    bool Refused,
    int Status,
    string Output
);
