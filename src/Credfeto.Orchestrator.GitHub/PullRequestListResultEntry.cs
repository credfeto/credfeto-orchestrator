using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// Author is the login, "app/<name>" for a bot or "-" when GitHub has none; Head is the head branch; Labels are the
// label names; ClosingIssues is only present when asked for. The reads that only need the number leave the rest
// unchecked
[DebuggerDisplay("#{Number}")]
internal sealed record PullRequestListResultEntry(
    int Number,
    string? Author,
    IReadOnlyList<string?>? Labels,
    string? Head = null,
    IReadOnlyList<ClosingIssueResult?>? ClosingIssues = null
);
