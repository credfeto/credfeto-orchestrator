using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.State;

// Options holds every option the query takes, by name without its leading dashes; a value may be empty
[DebuggerDisplay("Query={Query}")]
public sealed record StateCommand(StateQuery Query, IReadOnlyDictionary<string, string> Options)
{
    public string Option(string name)
    {
        return this.Options[name];
    }
}
