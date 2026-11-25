using System.Collections.Generic;

namespace Credfeto.Orchestrator.Prompts;

// build_pr_claude_md: the verify-only dependency prompt, or the full phase flow
internal static class PullRequestClaudeMdBuilder
{
    private const string PR = SharedSections.PULL_REQUEST;

    public static string Build(PromptTemplateSet templates, PullRequestClaudeMdRequest request)
    {
        List<TemplateValue> values = SharedSections.Common(
            templates: templates,
            itemId: request.ItemId,
            aiInstructions: request.AiInstructions,
            repository: request.Board.Repository,
            repositoryPath: request.RepositoryPath
        );
        values.AddOutput(
            name: "trusted_commenters",
            output: TrustedCommenters.Section(templates: templates, request.Session.TrustedLogins)
        );
        values.AddOutput(
            name: "permission_denial_rule",
            output: SharedSections.PermissionDenialRule(
                templates: templates,
                board: request.Board,
                itemKind: PR,
                itemId: request.ItemId
            )
        );
        values.AddOutput(
            name: "placeholder_disarm",
            output: PullRequestSections.PlaceholderDisarm(
                templates: templates,
                repository: request.Board.Repository,
                itemId: request.ItemId
            )
        );

        if (BashText.IsTrue(request.Session.IsDependencyPullRequest))
        {
            return DependencyFlow(templates: templates, request: request, values: values);
        }

        return FullFlow(templates: templates, request: request, values: values);
    }

    private static string DependencyFlow(
        PromptTemplateSet templates,
        PullRequestClaudeMdRequest request,
        List<TemplateValue> values
    )
    {
        values.AddOutput(
            name: "dependency_pr_rule_verify",
            output: PullRequestSections.DependencyRule(templates: templates, "verify")
        );
        values.AddOutput(
            name: "first_command_rule_indented",
            output: PullRequestSections.FirstCommandRule(
                templates: templates,
                repository: request.Board.Repository,
                pullRequestNumber: request.ItemId,
                indent: "   "
            )
        );
        values.AddOutput(
            name: "placeholder_guard_stop",
            output: PullRequestSections.PlaceholderGuard(
                templates: templates,
                repository: request.Board.Repository,
                itemId: request.ItemId,
                mode: "stop"
            )
        );

        return BashText.Line(templates.Render(name: "DependencyPullRequestClaudeMd", values: values));
    }

    private static string FullFlow(
        PromptTemplateSet templates,
        PullRequestClaudeMdRequest request,
        List<TemplateValue> values
    )
    {
        BoardSettings board = request.Board;
        PullRequestSession session = request.Session;

        values.AddOutput(
            name: "workflow_board_section",
            output: SharedSections.WorkflowBoardSection(
                templates: templates,
                board: board,
                itemKind: PR,
                itemId: request.ItemId
            )
        );
        values.AddOutput(
            name: "first_command_rule",
            output: PullRequestSections.FirstCommandRule(
                templates: templates,
                repository: board.Repository,
                pullRequestNumber: request.ItemId,
                indent: string.Empty
            )
        );
        values.AddValue(name: "precheck_block", value: SharedSections.PrecheckBlock(session.PrecheckSection));
        values.AddOutput(
            name: "background_stall_warning",
            output: SharedSections.BackgroundStallWarning(templates: templates, session.BackgroundStall)
        );
        AddAssignRule(templates: templates, request: request, values: values);
        values.AddOutput(
            name: "trusted_comments_section",
            output: PullRequestSections.TrustedComments(templates: templates, session.UnaddressedComments)
        );
        values.AddOutput(
            name: "next_phase_section",
            output: PullRequestSections.NextPhase(templates: templates, session.NextPhase)
        );
        values.AddValue(
            name: "checkout_step",
            value: PullRequestCheckout.Step(
                templates: templates,
                mergeState: request.MergeState,
                branchName: request.BranchName,
                repositoryPath: request.RepositoryPath,
                dirtyBranch: request.DirtyBranch
            )
        );
        AddPhaseValues(
            templates: templates,
            board: board,
            review: request.Review,
            itemId: request.ItemId,
            values: values
        );

        return BashText.Line(templates.Render(name: "PullRequestClaudeMd", values: values));
    }

    // A dependency branch gets the DEPENDENCY PR RULE instead of the assign step, and a blank line after it
    private static void AddAssignRule(
        PromptTemplateSet templates,
        PullRequestClaudeMdRequest request,
        List<TemplateValue> values
    )
    {
        if (BashText.IsTrue(request.Session.DependencyBranch))
        {
            values.AddValue(name: "assign_rule", value: templates.Text("AssignRuleDependency"));
            values.AddValue(
                name: "dependency_rule_block",
                value: BashText.Substitution(PullRequestSections.DependencyRule(templates: templates, "full")) + "\n\n"
            );

            return;
        }

        values.AddValue(
            name: "assign_rule",
            value: templates.Render(
                name: "AssignRule",
                values:
                [
                    new(Name: "repo_full", Value: request.Board.Repository),
                    new(Name: "item_id", Value: request.ItemId),
                ]
            )
        );
        values.AddValue(name: "dependency_rule_block", value: string.Empty);
    }

    private static void AddPhaseValues(
        PromptTemplateSet templates,
        BoardSettings board,
        ReviewSettings review,
        string itemId,
        List<TemplateValue> values
    )
    {
        foreach ((string name, string status) in BoardStatuses)
        {
            values.AddOutput(
                name: name,
                output: SharedSections.Clause(
                    templates: templates,
                    board: board,
                    itemKind: PR,
                    itemId: itemId,
                    status: status
                )
            );
        }

        ReviewMarkers markers = review.Markers;
        values.AddValue(name: "round_marker_simplify", value: markers.Simplify);
        values.AddValue(name: "round_marker_coverage", value: markers.Coverage);
        values.AddValue(name: "review_result_clean_marker", value: markers.ReviewResultClean);
        values.AddValue(name: "review_result_findings_marker", value: markers.ReviewResultFindings);
        values.AddValue(name: "simplify_thrash_limit", value: review.SimplifyThrashLimit);
        values.AddValue(name: "max_simplify_iterations", value: review.MaxSimplifyIterations);
        values.AddValue(name: "max_coverage_iterations", value: review.MaxCoverageIterations);
        values.AddOutput(
            name: "review_convergence_code",
            output: ReviewConvergence.CodeReview(templates: templates, board: board, review: review, itemId: itemId)
        );
        values.AddOutput(
            name: "review_convergence_security",
            output: ReviewConvergence.SecurityReview(templates: templates, board: board, review: review, itemId: itemId)
        );
        values.AddOutput(
            name: "round_cap_line_coverage",
            output: ReviewConvergence.CoverageRoundCap(templates: templates, review)
        );
        values.AddOutput(
            name: "placeholder_guard_remove",
            output: PullRequestSections.PlaceholderGuard(
                templates: templates,
                repository: board.Repository,
                itemId: itemId,
                mode: "remove"
            )
        );
    }

    // The board statuses the phases move a pull request to, each quoted with its $(_board_set_clause pr ...)
    private static readonly (string Name, string Status)[] BoardStatuses =
    [
        ("board_development", "Development"),
        ("board_ai_simplify", "AI Simplify"),
        ("board_ai_review", "AI Review"),
        ("board_ai_security_review", "AI Security Review"),
        ("board_ai_coverage", "AI Coverage"),
        ("board_human_review", "Human Review"),
    ];
}
