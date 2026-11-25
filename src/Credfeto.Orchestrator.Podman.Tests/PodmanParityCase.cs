using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman.Tests;

// One case of test/fixtures/podman-parity.json: Argument, Stdout and each response's arguments and output are printf
// %b text; Calls holds each podman call bash made, its arguments joined and ended by \x1f
[DebuggerDisplay("Function={Function}, Tool={Tool}, Status={Status}")]
public sealed record PodmanParityCase(
    string Function,
    string Argument,
    string Tool,
    IReadOnlyList<PodmanParityResponse> Responses,
    string Stdout,
    int Status,
    IReadOnlyList<string> Calls
);
