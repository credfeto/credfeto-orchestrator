namespace Credfeto.Orchestrator.Prompts;

// The lib/prompts helpers only build_pr_claude_md uses
internal static class PullRequestSections
{
    private const string VERIFY_FLOW = "verify";

    // _build_pr_first_command_rule: every line of the rule with the indent in front of it
    public static string FirstCommandRule(
        PromptTemplateSet templates,
        string repository,
        string pullRequestNumber,
        string indent
    )
    {
        string rule = templates.Render(
            name: "PullRequestFirstCommandRule",
            values: [new(Name: "repo_full", Value: repository), new(Name: "pr_number", Value: pullRequestNumber)]
        );

        return indent
            + rule.Replace(oldValue: "\n", newValue: "\n" + indent, comparisonType: System.StringComparison.Ordinal)
            + "\n";
    }

    // _build_dependency_pr_rule: flow "verify" is the verify-only dependency prompt, anything else the full flow
    public static string DependencyRule(PromptTemplateSet templates, string flow)
    {
        bool verify = System.StringComparer.Ordinal.Equals(x: flow, y: VERIFY_FLOW);

        return BashText.Line(
            templates.Render(
                name: "DependencyPullRequestRule",
                values:
                [
                    new(
                        Name: "comments_step",
                        Value: templates.Text(verify ? "DependencyCommentsStepVerify" : "DependencyCommentsStepFull")
                    ),
                    new(
                        Name: "then_step",
                        Value: templates.Text(verify ? "DependencyThenStepVerify" : "DependencyThenStepFull")
                    ),
                ]
            )
        );
    }

    // _build_pr_trusted_comments_section: the step, and the unaddressed comments oneshot found, when there are any
    public static string TrustedComments(PromptTemplateSet templates, string unaddressedComments)
    {
        string step = BashText.Line(templates.Text("PullRequestTrustedComments"));

        return unaddressedComments.Length == 0
            ? step
            : step
                + BashText.Line(templates.Text("PullRequestTrustedCommentsFound"))
                + BashText.Line(unaddressedComments);
    }

    // _build_pr_next_phase_section
    public static string NextPhase(PromptTemplateSet templates, string nextPhase)
    {
        return nextPhase.Length == 0
            ? string.Empty
            : BashText.Line(
                templates.Render(name: "PullRequestNextPhase", values: [new(Name: "next_phase", Value: nextPhase)])
            );
    }

    // _build_placeholder_guard_note: mode "remove" takes a leftover placeholder out, anything else only stops
    public static string PlaceholderGuard(PromptTemplateSet templates, string repository, string itemId, string mode)
    {
        return templates.Render(
            name: System.StringComparer.Ordinal.Equals(x: mode, y: "remove")
                ? "PlaceholderGuardRemove"
                : "PlaceholderGuardStop",
            values: [new(Name: "repo_full", Value: repository), new(Name: "item_id", Value: itemId)]
        );
    }

    // _build_placeholder_disarm_note
    public static string PlaceholderDisarm(PromptTemplateSet templates, string repository, string itemId)
    {
        return templates.Render(
            name: "PlaceholderDisarm",
            values: [new(Name: "repo_full", Value: repository), new(Name: "item_id", Value: itemId)]
        );
    }

    // _build_round_cap_check_line
    public static string RoundCapCheckLine(
        PromptTemplateSet templates,
        string maxIterations,
        string roundNoun,
        string capCondition,
        string postClause
    )
    {
        return BashText.Line(
            templates.Render(
                name: "RoundCapCheckLine",
                values:
                [
                    new(Name: "max_iter", Value: maxIterations),
                    new(Name: "round_noun", Value: roundNoun),
                    new(Name: "cap_condition", Value: capCondition),
                    new(Name: "post_clause", Value: postClause),
                ]
            )
        );
    }
}
