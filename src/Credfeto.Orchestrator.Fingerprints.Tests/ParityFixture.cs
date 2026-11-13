using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Fingerprints.Tests;

// test/fixtures/fingerprint-parity.json, embedded: the golden fingerprints test/oneshot-fingerprint-parity.bats
// checks the shell version against
internal static class ParityFixture
{
    public const string PullRequests = "pullRequests";
    public const string Issues = "issues";

    private const string RESOURCE_NAME = "fingerprint-parity.json";

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

    public static async Task<ParityCase> CaseAsync(string collection, int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty(collection)[index];
        bool pullRequest = StringComparer.Ordinal.Equals(x: collection, y: PullRequests);

        return new(
            Name: item.GetProperty("name").GetString() ?? string.Empty,
            Item: TextOrJson(
                item: item,
                textName: pullRequest ? "prText" : "issueText",
                jsonName: pullRequest ? "pr" : "issue"
            ) ?? string.Empty,
            Trusted: TextOrJson(item: item, textName: "trustedText", jsonName: "trusted"),
            ReviewComments: TextOrJson(item: item, textName: "reviewCommentsText", jsonName: "reviewComments"),
            PlanApproved: item.TryGetProperty(propertyName: "planApproved", value: out JsonElement plan)
                ? plan.GetString()
                : null,
            Expected: item.GetProperty("expected").GetString()
        );
    }

    private static string? TextOrJson(in JsonElement item, string textName, string jsonName)
    {
        if (item.TryGetProperty(propertyName: textName, value: out JsonElement text))
        {
            return text.GetString();
        }

        return item.TryGetProperty(propertyName: jsonName, value: out JsonElement json) ? json.GetRawText() : null;
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream =
            typeof(ParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
