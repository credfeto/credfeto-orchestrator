using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Discord.Tests;

// One case of test/fixtures/discord-parity.json: the payload kind and options its function hands the tool, its
// arguments as printf %b text, and what the shell function printed and returned
[DebuggerDisplay("Kind={Kind}, Tool={Tool}, Status={Status}")]
public sealed record DiscordParityCase(
    string Kind,
    IReadOnlyList<string> Options,
    IReadOnlyList<string> Arguments,
    string Tool,
    string Stdout,
    int Status
);
