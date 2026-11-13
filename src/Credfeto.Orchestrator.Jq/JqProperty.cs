using System.Diagnostics;

namespace Credfeto.Orchestrator.Jq;

[DebuggerDisplay("{Name}: {Value}")]
public readonly record struct JqProperty(string Name, JqValue Value);
