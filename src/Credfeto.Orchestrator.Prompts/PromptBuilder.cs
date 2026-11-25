namespace Credfeto.Orchestrator.Prompts;

public sealed class PromptBuilder : IPromptBuilder
{
    private readonly PromptTemplateSet _templates;

    public PromptBuilder(PromptTemplateSet templates)
    {
        this._templates = templates;
    }

    // build_issue_claude_md
    public string IssueClaudeMd(IssueClaudeMdRequest request)
    {
        return IssueClaudeMdBuilder.Build(templates: this._templates, request: request);
    }

    // build_pr_claude_md
    public string PullRequestClaudeMd(PullRequestClaudeMdRequest request)
    {
        return PullRequestClaudeMdBuilder.Build(templates: this._templates, request: request);
    }

    // build_issue_prompt
    public string IssueLaunchPrompt(LaunchPromptRequest request)
    {
        return Launch(templates: this._templates, name: "IssueLaunchPrompt", request: request);
    }

    // build_pr_prompt
    public string PullRequestLaunchPrompt(LaunchPromptRequest request)
    {
        return Launch(templates: this._templates, name: "PullRequestLaunchPrompt", request: request);
    }

    // build_precheck_section
    public string PrecheckSection(PrecheckSectionRequest request)
    {
        return PrecheckSectionBuilder.Build(templates: this._templates, request: request);
    }

    private static string Launch(PromptTemplateSet templates, string name, LaunchPromptRequest request)
    {
        return BashText.Line(
            templates.Render(
                name: name,
                values:
                [
                    new(Name: "item_id", Value: request.ItemId),
                    new(Name: "repo_full", Value: request.Repository),
                    new(Name: "repo_path", Value: request.RepositoryPath),
                ]
            )
        );
    }
}
