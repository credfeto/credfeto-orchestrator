using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Discord;

// discord <text command> with every option it takes, by name without the leading --
[DebuggerDisplay("Kind={Kind}")]
public sealed record DiscordTextCommand(DiscordTextKind Kind, IReadOnlyDictionary<string, string> Options)
{
    // Whether the command reads its input on stdin, as the lib/discord function hands it over in a here-string
    public bool ReadsInput => this.Kind != DiscordTextKind.ITEM_STATUS;
}
