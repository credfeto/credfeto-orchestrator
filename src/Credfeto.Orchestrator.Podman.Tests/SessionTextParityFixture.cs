using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// test/fixtures/podman-text-parity.json, embedded: the golden cases test/oneshot-podman-text-parity.bats checks the
// shell version against. A case without a locale runs in each of the locales the bats file checks.
internal static class SessionTextParityFixture
{
    private const string RESOURCE_NAME = "podman-text-parity.json";

    private static readonly string[] AllLocales = ["C.UTF-8", "en_GB.UTF-8", "C"];

    public static async Task<TheoryData<int, string>> CaseNamesAsync()
    {
        using JsonDocument document = await EmbeddedFixture.LoadAsync(
            resourceName: RESOURCE_NAME,
            cancellationToken: CancellationToken.None
        );
        JsonElement messages = document.RootElement.GetProperty("messages");
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            string message = Text(item: messages[item.GetProperty("message").GetInt32()], name: "name");
            cases.Add(p1: index, p2: Text(item: item, name: "function") + ": " + message);
            index++;
        }

        return cases;
    }

    public static async Task<SessionTextParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await EmbeddedFixture.LoadAsync(
            resourceName: RESOURCE_NAME,
            cancellationToken: cancellationToken
        );
        JsonElement root = document.RootElement;
        JsonElement item = root.GetProperty("cases")[index];
        JsonElement function = root.GetProperty("functions").GetProperty(Text(item: item, name: "function"));
        JsonElement arguments = item.TryGetProperty("args", out JsonElement own) ? own : function.GetProperty("args");
        JsonElement message = root.GetProperty("messages")[item.GetProperty("message").GetInt32()];

        return new(
            Query: Text(item: function, name: "query"),
            Arguments: [.. arguments.EnumerateArray().Select(argument => argument.GetString() ?? string.Empty)],
            Text: Text(item: message, name: "text"),
            Locales: item.TryGetProperty("locale", out JsonElement locale)
                ? [locale.GetString() ?? string.Empty]
                : AllLocales,
            Tool: Text(item: item, name: "tool"),
            Stdout: Text(item: item, name: "stdout"),
            Status: item.GetProperty("status").GetInt32()
        );
    }

    private static string Text(JsonElement item, string name)
    {
        return item.GetProperty(name).GetString() ?? string.Empty;
    }
}
