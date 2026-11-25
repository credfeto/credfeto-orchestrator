using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.Discord;

// The payload cannot be built exactly as the bash version would build it, so bash must build it
[Description("The Discord payload cannot be built exactly as bash would")]
public sealed partial class DiscordRefusedException : Exception;
