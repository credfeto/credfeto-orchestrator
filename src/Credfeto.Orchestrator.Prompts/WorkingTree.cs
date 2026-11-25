using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// The branch a dirty checkout is on (empty: clean), and the item's resumable branch (empty: none)
[DebuggerDisplay("Dirty={DirtyBranch}, Stale={StaleBranch}")]
public sealed record WorkingTree(string DirtyBranch, string StaleBranch);
