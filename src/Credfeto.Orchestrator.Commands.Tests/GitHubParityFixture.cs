using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

// test/fixtures/github-parity.json, embedded: the golden cases test/oneshot-github-parity.bats checks the shell
// version against. Each case holds the gh responses the shell reads, the cfwf MCP server result the tool reads, and
// what both must print (null when both must fail).
internal static class GitHubParityFixture
{
    public static readonly GitHubParityRead OpenPullRequests = new(
        Collection: "openPullRequests",
        Read: "open-prs",
        NameField: "head",
        ExpectedField: "numbers",
        Tool: "pr_list",
        NameArgument: "head"
    );

    public static readonly GitHubParityRead OpenPullRequestCount = OpenPullRequests with
    {
        Read = "open-pr-count",
        ExpectedField = "count",
    };

    public static readonly GitHubParityRead BranchRequiresStatusChecks = new(
        Collection: "branchRequiresStatusChecks",
        Read: "branch-requires-status-checks",
        NameField: "branch",
        ExpectedField: "expected",
        Tool: "branch_required_checks",
        NameArgument: "branch"
    );

    private const string RESOURCE_NAME = "github-parity.json";

    public static async Task<TheoryData<int, string>> CaseNamesAsync(string collection)
    {
        using JsonDocument document = await LoadAsync(CancellationToken.None);
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty(collection).EnumerateArray())
        {
            cases.Add(p1: index, p2: item.GetProperty("name").GetString() ?? string.Empty);
            index++;
        }

        return cases;
    }

    public static async Task<GitHubParityCase> CaseAsync(
        GitHubParityRead read,
        int index,
        CancellationToken cancellationToken
    )
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty(read.Collection)[index];

        return new(
            Case: item.GetProperty("name").GetString() ?? string.Empty,
            Repository: item.GetProperty("repo").GetString() ?? string.Empty,
            Name: item.GetProperty(read.NameField).GetString() ?? string.Empty,
            McpResult: item.TryGetProperty(propertyName: "mcp", value: out JsonElement mcp) ? mcp.GetRawText() : null,
            McpError: item.TryGetProperty(propertyName: "mcpError", value: out JsonElement error)
                ? error.GetString()
                : null,
            Expected: item.GetProperty(read.ExpectedField).GetString()
        );
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream =
            typeof(GitHubParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
