using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Predicates;

// Options maps each of the query's options (without the leading --) to its value; every one is present exactly once
[DebuggerDisplay("Query={Query}")]
public sealed record ChecksCommand(ChecksQuery Query, IReadOnlyDictionary<string, string> Options)
{
    public string Option(string name)
    {
        return this.Options[name];
    }
}
