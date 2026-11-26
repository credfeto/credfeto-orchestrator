using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman.Tests;

// One case of test/fixtures/podman-result-parity.json: Result (the result file's content) and Stdout are printf %b text
[DebuggerDisplay("Function={Function}, Tool={Tool}, Status={Status}")]
public sealed record ClaudeResultParityCase(string Function, string Result, string Tool, string Stdout, int Status);
