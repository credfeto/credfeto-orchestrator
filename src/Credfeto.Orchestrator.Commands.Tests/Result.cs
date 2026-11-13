using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands.Tests;

[DebuggerDisplay("ExitCode={ExitCode}, Output={Output}, Error={Error}")]
public sealed record Result(int ExitCode, string Output, string Error);
