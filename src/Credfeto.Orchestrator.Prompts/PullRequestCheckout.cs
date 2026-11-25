using System;

namespace Credfeto.Orchestrator.Prompts;

// PHASE A's checkout_step in build_pr_claude_md: what to do with a dirty working tree and a BEHIND or DIRTY branch
internal static class PullRequestCheckout
{
    public static string Step(
        PromptTemplateSet templates,
        string mergeState,
        string branchName,
        string repositoryPath,
        string dirtyBranch
    )
    {
        bool needsRebase =
            StringComparer.Ordinal.Equals(x: mergeState, y: "BEHIND")
            || StringComparer.Ordinal.Equals(x: mergeState, y: "DIRTY");
        bool dirty = dirtyBranch.Length != 0;
        bool ownBranch = dirty && StringComparer.Ordinal.Equals(x: dirtyBranch, y: branchName);

        string template = (dirty, ownBranch, needsRebase) switch
        {
            (true, true, true) => "CheckoutOwnDirtyRebase",
            (true, true, false) => "CheckoutOwnDirty",
            (true, false, true) => "CheckoutDirtyRebase",
            (true, false, false) => "CheckoutDirty",
            (false, _, true) => "CheckoutRebase",
            _ => "CheckoutBranch",
        };

        return templates.Render(
            name: template,
            values:
            [
                new(Name: "merge_state", Value: mergeState),
                new(Name: "branch_name", Value: branchName),
                new(Name: "repo_path", Value: repositoryPath),
                new(Name: "dirty_branch", Value: dirtyBranch),
                new(
                    Name: "rebase_continue_rule",
                    Value: templates.Render(
                        name: "RebaseContinueRule",
                        values: [new(Name: "repo_path", Value: repositoryPath)]
                    )
                ),
            ]
        );
    }
}
