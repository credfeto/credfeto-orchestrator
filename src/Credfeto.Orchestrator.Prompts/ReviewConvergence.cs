namespace Credfeto.Orchestrator.Prompts;

// _build_review_convergence_block for PHASE E (code review) and PHASE F (security review), and PHASE G's round cap line
internal static class ReviewConvergence
{
    public static string CodeReview(
        PromptTemplateSet templates,
        BoardSettings board,
        ReviewSettings review,
        string itemId
    )
    {
        return Block(
            templates: templates,
            board: board,
            itemId: itemId,
            phase: new(
                Label: "code-review",
                NextStatus: "AI Security Review",
                MaxIterations: review.MaxCodeReviewIterations,
                FixStep: templates.Render(
                    name: "CodeReviewFixStep",
                    values: [new(Name: "round_marker_code_review", Value: review.Markers.CodeReview)]
                ),
                DownstreamNote: templates.Text("CodeReviewDownstreamNote"),
                MinRounds: review.MinReviewConvergenceRounds
            )
        );
    }

    public static string SecurityReview(
        PromptTemplateSet templates,
        BoardSettings board,
        ReviewSettings review,
        string itemId
    )
    {
        return Block(
            templates: templates,
            board: board,
            itemId: itemId,
            phase: new(
                Label: "security-review",
                NextStatus: "AI Coverage",
                MaxIterations: review.MaxSecurityReviewIterations,
                FixStep: templates.Render(
                    name: "SecurityReviewFixStep",
                    values: [new(Name: "round_marker_security_review", Value: review.Markers.SecurityReview)]
                ),
                DownstreamNote: templates.Text("SecurityReviewDownstreamNote"),
                MinRounds: review.MinReviewConvergenceRounds
            )
        );
    }

    // PHASE G's $(_build_round_cap_check_line ...)
    public static string CoverageRoundCap(PromptTemplateSet templates, ReviewSettings review)
    {
        return PullRequestSections.RoundCapCheckLine(
            templates: templates,
            maxIterations: review.MaxCoverageIterations,
            roundNoun: "coverage rounds",
            capCondition: templates.Render(
                name: "CoverageCapCondition",
                values: [new(Name: "round_marker_coverage", Value: review.Markers.Coverage)]
            ),
            postClause: templates.Text("CoverageCapPostClause")
        );
    }

    private static string Block(PromptTemplateSet templates, BoardSettings board, string itemId, ReviewPhase phase)
    {
        string capCondition = templates.Render(
            name: "ReviewCapCondition",
            values: [new(Name: "review_label", Value: phase.Label)]
        );
        string roundCapLine = PullRequestSections.RoundCapCheckLine(
            templates: templates,
            maxIterations: phase.MaxIterations,
            roundNoun: phase.Label + " rounds",
            capCondition: capCondition,
            postClause: templates.Text("ReviewCapPostClause")
        );

        return BashText.Line(
            templates.Render(
                name: "ReviewConvergenceBlock",
                values:
                [
                    new(Name: "review_label", Value: phase.Label),
                    new(Name: "review_noun", Value: phase.Label.Replace(oldChar: '-', newChar: ' ')),
                    new(Name: "round_cap_line", Value: BashText.Substitution(roundCapLine)),
                    new(Name: "min_rounds", Value: phase.MinRounds),
                    new(Name: "next_status", Value: phase.NextStatus),
                    new(
                        Name: "board_next_status",
                        Value: SharedSections.Clause(
                            templates: templates,
                            board: board,
                            itemKind: SharedSections.PULL_REQUEST,
                            itemId: itemId,
                            status: phase.NextStatus
                        )
                    ),
                    new(Name: "downstream_note", Value: phase.DownstreamNote),
                    new(Name: "fix_step", Value: phase.FixStep),
                ]
            )
        );
    }
}
