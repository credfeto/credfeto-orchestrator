using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// An open pull request as the issue stand-off reads it: Author is the login (empty when GitHub has none),
// ClosingIssues the numbers of the issues it closes, in any repository, and Head its head branch
[DebuggerDisplay("#{Number} by {Author} on {Head}")]
public sealed record OpenPullRequestReferences(
    int Number,
    string Author,
    IReadOnlyList<int> ClosingIssues,
    string Head
);
