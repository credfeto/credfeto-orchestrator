using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

[DebuggerDisplay("ExitCode={ExitCode}, Printed={Printed}, Problem={Problem}")]
public sealed record PredicateOutcome(string Printed, int ExitCode, string? Problem);
