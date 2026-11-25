using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// What oneshot found about the pull request before the session: which prompt it gets and what to quote in it
[DebuggerDisplay("Dependency={IsDependencyPullRequest}, NextPhase={NextPhase}")]
public sealed record PullRequestSession(
    string IsDependencyPullRequest,
    string DependencyBranch,
    string TrustedLogins,
    string BackgroundStall,
    string UnaddressedComments,
    string NextPhase,
    string PrecheckSection
);
