using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The collaborator's role is not read: gh api repos/<repo>/collaborators, which the shell version reads, lists every
// collaborator whatever their role
[DebuggerDisplay("{Login}")]
internal sealed record RepositoryCollaboratorsResultEntry(string? Login);
