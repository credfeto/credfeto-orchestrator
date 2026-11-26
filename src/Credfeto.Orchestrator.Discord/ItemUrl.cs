namespace Credfeto.Orchestrator.Discord;

// lib/discord's build_item_url, as a caller captures it with $(...)
public static class ItemUrl
{
    // The issue or pull request URL for item_type Issue or PullRequest, else the repository's own; the repository
    // is defaultRepo (REPO_FULL) when repo is empty. Command substitution drops the URL's trailing newlines, which
    // only a repository name can bring.
    public static string Build(string itemType, string itemId, string repo, string defaultRepo)
    {
        string repository = repo.Length > 0 ? repo : defaultRepo;
        string url = itemType switch
        {
            "Issue" => $"https://github.com/{repository}/issues/{itemId}",
            "PullRequest" => $"https://github.com/{repository}/pull/{itemId}",
            _ => $"https://github.com/{repository}",
        };

        return url.TrimEnd('\n');
    }
}
