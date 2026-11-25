using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's repo_collaborators result the read uses; every other property is ignored
[DebuggerDisplay("Collaborators={Collaborators}")]
internal sealed record RepositoryCollaboratorsResult(IReadOnlyList<RepositoryCollaboratorsResultEntry?>? Collaborators);
