using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// build_issue_claude_md's arguments, after its defaults are applied
[DebuggerDisplay("Item={ItemId}, PlanApproved={PlanApproved}")]
public sealed record IssueClaudeMdRequest(
    BoardSettings Board,
    string ItemId,
    string AiInstructions,
    string RepositoryPath,
    string PlanApproved,
    string TrustedLogins,
    WorkingTree Tree,
    string BackgroundStall,
    string PrecheckSection
);
