using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Discord;

// discord payload <kind> with every option the kind takes, by name without the leading --
[DebuggerDisplay("Kind={Kind}")]
public sealed record DiscordCommand(DiscordPayloadKind Kind, IReadOnlyDictionary<string, string> Options);
