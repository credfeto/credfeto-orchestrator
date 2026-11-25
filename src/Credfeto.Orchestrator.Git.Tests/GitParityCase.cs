using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Git.Tests;

[DebuggerDisplay("Function={Function}, Scenario={Scenario}, Repository={Repository}, Tool={Tool}")]
public sealed record GitParityCase(
    string Function,
    string Scenario,
    string Repository,
    IReadOnlyList<string> Arguments,
    string Tool,
    string Stdout,
    int Status
);
