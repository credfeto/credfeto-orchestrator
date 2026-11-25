using System;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Git;

// What a git command, or a lib/git query built on git, printed on stdout (byte for byte) and the status it returned
[DebuggerDisplay("ExitCode={ExitCode}, Output={Output.Length} bytes")]
public sealed record GitResult(int ExitCode, ReadOnlyMemory<byte> Output);
