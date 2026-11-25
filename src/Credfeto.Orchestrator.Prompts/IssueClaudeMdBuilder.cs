using System.Collections.Generic;

namespace Credfeto.Orchestrator.Prompts;

// build_issue_claude_md
internal static class IssueClaudeMdBuilder
{
    public static string Build(PromptTemplateSet templates, IssueClaudeMdRequest request)
    {
        BoardSettings board = request.Board;
        List<TemplateValue> values = SharedSections.Common(
            templates: templates,
            itemId: request.ItemId,
            aiInstructions: request.AiInstructions,
            repository: board.Repository,
            repositoryPath: request.RepositoryPath
        );

        AddContextSections(templates: templates, request: request, values: values);
        AddStepSections(templates: templates, request: request, values: values);

        return BashText.Line(templates.Render(name: "IssueClaudeMd", values: values));
    }

    // The sections ahead of the steps: who to trust, the board, the checkout's state and the pre-check
    private static void AddContextSections(
        PromptTemplateSet templates,
        IssueClaudeMdRequest request,
        List<TemplateValue> values
    )
    {
        BoardSettings board = request.Board;

        values.AddOutput(
            name: "trusted_commenters",
            output: TrustedCommenters.Section(templates: templates, request.TrustedLogins)
        );
        values.AddOutput(
            name: "workflow_board_section",
            output: SharedSections.WorkflowBoardSection(
                templates: templates,
                board: board,
                itemKind: SharedSections.ISSUE,
                itemId: request.ItemId
            )
        );
        values.AddOutput(
            name: "dirty_branch_section",
            output: IssueSections.DirtyBranchSection(
                templates: templates,
                tree: request.Tree,
                repositoryPath: request.RepositoryPath
            )
        );
        values.AddOutput(
            name: "stale_branch_section",
            output: IssueSections.StaleBranchSection(
                templates: templates,
                tree: request.Tree,
                repositoryPath: request.RepositoryPath
            )
        );
        values.AddValue(name: "precheck_block", value: SharedSections.PrecheckBlock(request.PrecheckSection));
        values.AddOutput(
            name: "background_stall_warning",
            output: SharedSections.BackgroundStallWarning(templates: templates, request.BackgroundStall)
        );
    }

    // The sections inside the numbered steps
    private static void AddStepSections(
        PromptTemplateSet templates,
        IssueClaudeMdRequest request,
        List<TemplateValue> values
    )
    {
        BoardSettings board = request.Board;

        values.AddOutput(
            name: "plan_approval_check",
            output: IssueSections.PlanApprovalCheck(
                templates: templates,
                board: board,
                itemId: request.ItemId,
                planApproved: request.PlanApproved
            )
        );
        values.AddOutput(
            name: "board_planning",
            output: SharedSections.Clause(
                templates: templates,
                board: board,
                itemKind: SharedSections.ISSUE,
                itemId: request.ItemId,
                status: "Planning"
            )
        );
        values.AddOutput(
            name: "plan_approval_instruction",
            output: IssueSections.PlanApprovalInstruction(templates: templates, board)
        );
        values.AddOutput(
            name: "branch_step",
            output: IssueSections.BranchStep(
                templates: templates,
                board: board,
                itemId: request.ItemId,
                repositoryPath: request.RepositoryPath,
                staleBranch: request.Tree.StaleBranch
            )
        );
        values.AddOutput(
            name: "permission_denial_rule",
            output: SharedSections.PermissionDenialRule(
                templates: templates,
                board: board,
                itemKind: SharedSections.ISSUE,
                itemId: request.ItemId
            )
        );
    }
}
