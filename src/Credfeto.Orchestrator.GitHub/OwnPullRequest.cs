using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

[DebuggerDisplay("#{Number} by {Author}")]
internal sealed record OwnPullRequest(int Number, string Author, IReadOnlyList<string> Labels);
