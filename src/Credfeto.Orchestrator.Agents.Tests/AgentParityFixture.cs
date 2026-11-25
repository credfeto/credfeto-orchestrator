using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

// test/fixtures/agents-parity.json, embedded: the golden cases test/oneshot-agents-parity.bats checks the shell version
// against
internal static class AgentParityFixture
{
    private const string RESOURCE_NAME = "agents-parity.json";

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

    public static async Task<AgentParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];

        return new(
            Agent: Text(item: item, name: "agent"),
            Reply: item.TryGetProperty(propertyName: "reply", value: out JsonElement reply)
                ? reply.GetString() ?? string.Empty
                : string.Empty,
            Tool: Text(item: item, name: "tool"),
            Status: item.GetProperty("status").GetInt32()
        );
    }

    private static string Text(JsonElement item, string name)
    {
        return item.GetProperty(name).GetString() ?? string.Empty;
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(AgentParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
