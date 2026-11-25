using System;
using System.Diagnostics;

namespace Credfeto.Orchestrator.State;

// What the lib/state function prints, byte for byte, and the status it returns
[DebuggerDisplay("ExitCode={ExitCode}")]
public readonly record struct StateResult(ReadOnlyMemory<byte> Output, int ExitCode);
