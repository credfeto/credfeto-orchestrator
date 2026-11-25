using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

[DebuggerDisplay("Trusted={Trusted}")]
internal sealed record CommentInputs(string Trusted, string ReviewComments, string IssueComments);
