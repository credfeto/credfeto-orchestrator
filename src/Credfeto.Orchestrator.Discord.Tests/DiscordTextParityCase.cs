using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Discord.Tests;

// One case of test/fixtures/discord-text-parity.json: the lib/discord function, its arguments as printf %b text,
// REPO_FULL (null when unset), the locale it ran in (empty for the UTF-8 locales), and what the shell function printed
// and returned
[DebuggerDisplay("Function={Function}, Tool={Tool}, Status={Status}")]
public sealed record DiscordTextParityCase(
    string Function,
    IReadOnlyList<string> Arguments,
    string? RepoFull,
    string Locale,
    string Tool,
    string Stdout,
    int Status
);
