using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.State.Tests;

// One case of test/fixtures/state-parity.json: Arguments, Stdout, Remaining and each file's path, content and link
// target are printf %b text
[DebuggerDisplay("Function={Function}, Tool={Tool}, Status={Status}")]
public sealed record StateParityCase(
    string Function,
    IReadOnlyList<string> Arguments,
    IReadOnlyList<StateParityFile> Files,
    IReadOnlyDictionary<string, string> Globals,
    string Tool,
    string Stdout,
    int Status,
    IReadOnlyList<string> Remaining
);
