using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman.Tests;

// One case of test/fixtures/podman-text-parity.json: Text (the message) and Stdout are printf %b text; Arguments are
// what the function passes the tool after the two locale options; Locales the locales the case runs in
[DebuggerDisplay("Query={Query}, Tool={Tool}, Status={Status}")]
public sealed record SessionTextParityCase(
    string Query,
    IReadOnlyList<string> Arguments,
    string Text,
    IReadOnlyList<string> Locales,
    string Tool,
    string Stdout,
    int Status
);
