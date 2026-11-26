using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// test/fixtures/podman-result-parity.json, embedded: the golden cases test/oneshot-podman-result-parity.bats checks the
// shell version against
internal static class ClaudeResultParityFixture
{
    private const string RESOURCE_NAME = "podman-result-parity.json";

    public static async Task<TheoryData<int, string>> CaseNamesAsync()
    {
        using JsonDocument document = await EmbeddedFixture.LoadAsync(
            resourceName: RESOURCE_NAME,
            cancellationToken: CancellationToken.None
        );
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            cases.Add(p1: index, p2: Text(item: item, name: "function") + ": " + Text(item: item, name: "name"));
            index++;
        }

        return cases;
    }

    public static async Task<ClaudeResultParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await EmbeddedFixture.LoadAsync(
            resourceName: RESOURCE_NAME,
            cancellationToken: cancellationToken
        );
        JsonElement item = document.RootElement.GetProperty("cases")[index];

        return new(
            Function: Text(item: item, name: "function"),
            Result: Text(item: item, name: "result"),
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
