using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// MaxLength is check-length's --max, and 0 for every other kind
[DebuggerDisplay("Kind={Kind}, MaxLength={MaxLength}")]
public sealed record PromptCommand(PromptKind Kind, int MaxLength);
