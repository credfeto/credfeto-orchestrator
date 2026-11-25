using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman.Tests;

// A podman call the fixture's stub answers: its arguments, then what it prints and returns
[DebuggerDisplay("Status={Status}")]
public sealed record PodmanParityResponse(IReadOnlyList<string> Arguments, string Stdout, string Stderr, int Status);
