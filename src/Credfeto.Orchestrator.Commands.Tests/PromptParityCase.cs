using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands.Tests;

// Refuses: the tool must fail (exit 1) so lib/prompts builds the text in bash; otherwise it must print Expected
[DebuggerDisplay("Kind={Kind}, Refuses={Refuses}")]
internal sealed record PromptParityCase(string Kind, bool Refuses, byte[] Records, string Expected);
