using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// build_pr_claude_md's arguments, after its defaults are applied
[DebuggerDisplay("Item={ItemId}, MergeState={MergeState}, Branch={BranchName}")]
public sealed record PullRequestClaudeMdRequest(
    BoardSettings Board,
    ReviewSettings Review,
    string ItemId,
    string AiInstructions,
    string MergeState,
    string BranchName,
    string RepositoryPath,
    string DirtyBranch,
    PullRequestSession Session
);
