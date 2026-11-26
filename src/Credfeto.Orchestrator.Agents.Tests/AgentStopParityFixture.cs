using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

// test/fixtures/agents-stop-parity.json, embedded: the golden cases test/oneshot-agents-stop-parity.bats checks the
// shell version against
internal static class AgentStopParityFixture
{
    private const string RESOURCE_NAME = "agents-stop-parity.json";

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

    public static async Task<AgentStopParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];
        JsonElement killed = item.GetProperty("killed");

        return new(
            Socket: Text(item: item, name: "socket"),
            Argv0: Text(item: item, name: "argv0"),
            Tool: Text(item: item, name: "tool"),
            Killed: killed.ValueKind == JsonValueKind.Null ? null : killed.GetBoolean()
        );
    }

    private static string Text(JsonElement item, string name)
    {
        return item.GetProperty(name).GetString() ?? string.Empty;
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(AgentStopParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
