using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// PullRequest is the pull request of the required check read (0 for the other), Sha the commit of the running check
// read (empty for the other)
[DebuggerDisplay("Read={Read}, Repository={Repository}, PullRequest={PullRequest}, Sha={Sha}")]
public sealed record ChecksReadCommand(ChecksRead Read, string Repository, int PullRequest, string Sha);
