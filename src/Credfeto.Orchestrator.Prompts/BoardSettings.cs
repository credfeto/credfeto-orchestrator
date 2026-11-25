using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// REPO_FULL, whether the repository has a Workflow board (_WF_PROJECT_ID is set) and _WF_STATUS_ORDER (lib/globals)
[DebuggerDisplay("Repository={Repository}, HasBoard={HasBoard}")]
public sealed record BoardSettings(string Repository, bool HasBoard, IReadOnlyList<string> Statuses);
