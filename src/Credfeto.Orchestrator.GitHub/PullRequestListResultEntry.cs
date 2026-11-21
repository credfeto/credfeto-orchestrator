using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// Author is the login, "app/<name>" for a bot or "-" when GitHub has none; Labels are the label names. The reads that
// only need the number leave both unchecked
[DebuggerDisplay("#{Number}")]
internal sealed record PullRequestListResultEntry(int Number, string? Author, IReadOnlyList<string?>? Labels);
