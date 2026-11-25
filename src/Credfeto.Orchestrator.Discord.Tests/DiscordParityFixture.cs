using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

// test/fixtures/discord-parity.json, embedded: the golden cases test/oneshot-discord-parity.bats checks the shell
// version against
internal static class DiscordParityFixture
{
    private const string RESOURCE_NAME = "discord-parity.json";

    public static async Task<TheoryData<int, string>> CaseNamesAsync()
    {
        using JsonDocument document = await LoadAsync(CancellationToken.None);
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            cases.Add(p1: index, p2: Text(item: item, name: "name"));
            index++;
        }

        return cases;
    }

    public static async Task<DiscordParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];
        JsonElement function = document
            .RootElement.GetProperty("functions")
            .GetProperty(Text(item: item, name: "function"));

        return new(
            Kind: Text(item: function, name: "kind"),
            Options: [.. function.GetProperty("options").EnumerateArray().Select(Text)],
            Arguments: [.. item.GetProperty("args").EnumerateArray().Select(Text)],
            Tool: Text(item: item, name: "tool"),
            Stdout: Text(item: item, name: "stdout"),
            Status: item.GetProperty("status").GetInt32()
        );
    }

    private static string Text(JsonElement item, string name)
    {
        return Text(item.GetProperty(name));
    }

    private static string Text(JsonElement value)
    {
        return value.GetString() ?? string.Empty;
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(DiscordParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
