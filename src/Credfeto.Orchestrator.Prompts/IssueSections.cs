using System;

namespace Credfeto.Orchestrator.Prompts;

// The lib/prompts helpers only build_issue_claude_md uses
internal static class IssueSections
{
    // _build_plan_approval_check
    public static string PlanApprovalCheck(
        PromptTemplateSet templates,
        BoardSettings board,
        string itemId,
        string planApproved
    )
    {
        if (BashText.IsTrue(planApproved))
        {
            return templates.Text("PlanApprovalCheckApproved");
        }

        return board.HasBoard
            ? templates.Text("PlanApprovalCheckBoard")
            : templates.Render(
                name: "PlanApprovalCheckComment",
                values: [new(Name: "repo_full", Value: board.Repository), new(Name: "item_id", Value: itemId)]
            );
    }

    // _build_plan_approval_instruction
    public static string PlanApprovalInstruction(PromptTemplateSet templates, BoardSettings board)
    {
        return templates.Text(board.HasBoard ? "PlanApprovalInstructionBoard" : "PlanApprovalInstructionComment");
    }

    // _build_issue_dirty_branch_section: dirty on the issue's own resumable branch keeps the work; dirty anywhere else
    // is cleaned up
    public static string DirtyBranchSection(PromptTemplateSet templates, WorkingTree tree, string repositoryPath)
    {
        if (tree.DirtyBranch.Length == 0)
        {
            return string.Empty;
        }

        bool ownBranch =
            tree.StaleBranch.Length != 0 && StringComparer.Ordinal.Equals(x: tree.DirtyBranch, y: tree.StaleBranch);

        return BashText.Line(
            templates.Render(
                name: ownBranch ? "IssueDirtyOwnBranch" : "IssueDirtyBranch",
                values:
                [
                    new(Name: "dirty_branch", Value: tree.DirtyBranch),
                    new(Name: "repo_path", Value: repositoryPath),
                ]
            )
        );
    }

    // _build_issue_stale_branch_section: left out when the checkout is dirty on that same branch
    public static string StaleBranchSection(PromptTemplateSet templates, WorkingTree tree, string repositoryPath)
    {
        if (tree.StaleBranch.Length == 0 || StringComparer.Ordinal.Equals(x: tree.StaleBranch, y: tree.DirtyBranch))
        {
            return string.Empty;
        }

        return BashText.Line(
            templates.Render(
                name: "IssueStaleBranch",
                values:
                [
                    new(Name: "stale_branch", Value: tree.StaleBranch),
                    new(Name: "repo_path", Value: repositoryPath),
                ]
            )
        );
    }

    // _build_issue_branch_step: continue on the resumable branch when there is one, otherwise open a new one
    public static string BranchStep(
        PromptTemplateSet templates,
        BoardSettings board,
        string itemId,
        string repositoryPath,
        string staleBranch
    )
    {
        string boardNote = templates.Render(
            name: "IssueBranchStepBoardNote",
            values:
            [
                new(
                    Name: "board_development",
                    Value: SharedSections.Clause(
                        templates: templates,
                        board: board,
                        itemKind: SharedSections.ISSUE,
                        itemId: itemId,
                        status: "Development"
                    )
                ),
            ]
        );

        return templates.Render(
            name: staleBranch.Length == 0 ? "IssueBranchStepNew" : "IssueBranchStepResume",
            values:
            [
                new(Name: "item_id", Value: itemId),
                new(Name: "repo_full", Value: board.Repository),
                new(Name: "repo_path", Value: repositoryPath),
                new(Name: "stale_branch", Value: staleBranch),
                new(Name: "board_note", Value: boardNote),
            ]
        );
    }
}
