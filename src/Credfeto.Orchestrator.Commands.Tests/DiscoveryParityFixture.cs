using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

// test/fixtures/discovery-parity.json, embedded: the golden cases test/oneshot-discovery-parity.bats checks the shell
// version against. Each case holds what the shell function reads and what it must print and return
internal static class DiscoveryParityFixture
{
    public const string GitHubHealth = "githubHealth";
    public const string Priorities = "priorities";
    public const string TrustedLogins = "trustedLogins";

    private const string RESOURCE_NAME = "discovery-parity.json";

    public static async Task<TheoryData<int, string>> CaseNamesAsync(string collection)
    {
        JsonElement root = await LoadAsync(CancellationToken.None);
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in Cases(root: root, collection: collection).EnumerateArray())
        {
            cases.Add(p1: index, p2: Text(element: item, name: "name"));
            index++;
        }

        return cases;
    }

    public static async Task<JsonElement> CaseAsync(string collection, int index, CancellationToken cancellationToken)
    {
        JsonElement root = await LoadAsync(cancellationToken);

        return Cases(root: root, collection: collection)[index];
    }

    public static async Task<IReadOnlyList<string>> GitHubHealthListAsync(
        string name,
        CancellationToken cancellationToken
    )
    {
        JsonElement root = await LoadAsync(cancellationToken);

        return Texts(root.GetProperty(GitHubHealth).GetProperty(name));
    }

    public static async Task<string> PriorityFeedUrlAsync(CancellationToken cancellationToken)
    {
        JsonElement root = await LoadAsync(cancellationToken);

        return Text(element: root, name: "priorityFeedUrl");
    }

    public static string Text(JsonElement element, string name)
    {
        return element.GetProperty(name).GetString() ?? string.Empty;
    }

    // A string, or null where the fixture has null
    public static string? OptionalText(JsonElement element, string name)
    {
        JsonElement value = element.GetProperty(name);

        return value.ValueKind == JsonValueKind.Null ? null : value.GetString();
    }

    public static IReadOnlyList<string?> OptionalTexts(JsonElement element)
    {
        return
        [
            .. element
                .EnumerateArray()
                .Select(static item => item.ValueKind == JsonValueKind.Null ? null : item.GetString()),
        ];
    }

    public static IReadOnlyList<string> Texts(JsonElement element)
    {
        return [.. element.EnumerateArray().Select(static item => item.GetString() ?? string.Empty)];
    }

    private static JsonElement Cases(JsonElement root, string collection)
    {
        JsonElement cases = root.GetProperty(collection);

        return cases.ValueKind == JsonValueKind.Object ? cases.GetProperty("cases") : cases;
    }

    private static async Task<JsonElement> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(DiscoveryParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);
        using JsonDocument document = await JsonDocument.ParseAsync(
            utf8Json: stream,
            cancellationToken: cancellationToken
        );

        return document.RootElement.Clone();
    }
}
