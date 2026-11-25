using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

[DebuggerDisplay("Repository={Repository}, Item={ItemId}")]
public sealed record LaunchPromptRequest(string Repository, string ItemId, string RepositoryPath);
