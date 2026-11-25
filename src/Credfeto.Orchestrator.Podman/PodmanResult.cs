using System;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman;

// What a podman command, or a lib/podman query built on podman, printed on stdout (byte for byte) and the status it
// returned
[DebuggerDisplay("ExitCode={ExitCode}, Output={Output.Length} bytes")]
public sealed record PodmanResult(int ExitCode, ReadOnlyMemory<byte> Output);
