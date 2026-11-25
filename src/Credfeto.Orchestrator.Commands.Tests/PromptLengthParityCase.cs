using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands.Tests;

[DebuggerDisplay("Locale={Locale}, Max={Max}, Length={Length}")]
internal sealed record PromptLengthParityCase(string Locale, string Max, byte[] Prompt, string Length, bool TooLong);
