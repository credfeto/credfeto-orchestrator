namespace Credfeto.Orchestrator.Prompts;

// The lib/prompts builders: each returns exactly what the shell function prints
public interface IPromptBuilder
{
    string IssueClaudeMd(IssueClaudeMdRequest request);

    string PullRequestClaudeMd(PullRequestClaudeMdRequest request);

    string IssueLaunchPrompt(LaunchPromptRequest request);

    string PullRequestLaunchPrompt(LaunchPromptRequest request);

    string PrecheckSection(PrecheckSectionRequest request);
}
