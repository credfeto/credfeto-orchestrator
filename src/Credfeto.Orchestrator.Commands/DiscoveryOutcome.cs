using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// What a discovery command prints on stdout, its exit code, and the problem to report on stderr, if any
[DebuggerDisplay("ExitCode={ExitCode}")]
public sealed record DiscoveryOutcome(int ExitCode, string Printed, string? Problem = null);
