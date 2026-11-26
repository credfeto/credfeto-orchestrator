using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.State.Tests;

// One case of test/fixtures/state-writes-parity.json: Arguments, Stdout and each file's path, content and link target
// are printf %b text; Left is every path left under the state directory, as StateWritesTree.ListAsync gives it
[DebuggerDisplay("Function={Function}, Tool={Tool}, Status={Status}")]
public sealed record StateWritesParityCase(
    string Function,
    IReadOnlyList<string> Arguments,
    int Umask,
    bool SessionDirectory,
    IReadOnlyList<StateWritesParityFile> Files,
    IReadOnlyDictionary<string, string> Globals,
    string Tool,
    string Stdout,
    int Status,
    IReadOnlyList<string> Left
);
