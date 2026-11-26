using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

// test/fixtures/discord-text-parity.json, embedded: the golden cases test/oneshot-discord-text-parity.bats checks the
// shell version against
internal static class DiscordTextParityFixture
{
    private const string RESOURCE_NAME = "discord-text-parity.json";

    public static async Task<TheoryData<int, string>> CaseNamesAsync()
    {
        TheoryData<int, string> cases = [];
        using JsonDocument document = await LoadAsync(CancellationToken.None);
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            cases.Add(p1: index, p2: Text(item.GetProperty("name")));
            index++;
        }

        return cases;
    }

    public static async Task<DiscordTextParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];

        return new(
            Function: Text(item.GetProperty("function")),
            Arguments: [.. item.GetProperty("args").EnumerateArray().Select(Text)],
            RepoFull: item.TryGetProperty(propertyName: "repo_full", value: out JsonElement repoFull)
                ? Text(repoFull)
                : null,
            Locale: item.TryGetProperty(propertyName: "locale", value: out JsonElement locale)
                ? Text(locale)
                : string.Empty,
            Tool: Text(item.GetProperty("tool")),
            Stdout: Text(item.GetProperty("stdout")),
            Status: item.GetProperty("status").GetInt32()
        );
    }

    private static string Text(JsonElement value)
    {
        return value.GetString() ?? string.Empty;
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(DiscordTextParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
