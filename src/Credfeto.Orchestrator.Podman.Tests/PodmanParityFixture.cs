using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// test/fixtures/podman-parity.json, embedded: the podman stand-in, and the golden cases test/oneshot-podman-parity.bats
// checks the shell version against
internal static class PodmanParityFixture
{
    private const string RESOURCE_NAME = "podman-parity.json";
    private const char CALL_SEPARATOR = '\u001f';

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

    public static async Task<PodmanParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];

        return new(
            Function: Text(item: item, name: "function"),
            Argument: Text(item: item, name: "arg"),
            Tool: Text(item: item, name: "tool"),
            Responses:
            [
                .. item.GetProperty("podman")
                    .EnumerateArray()
                    .Select(response => new PodmanParityResponse(
                        Arguments: [.. response.GetProperty("args").EnumerateArray().Select(Text)],
                        Stdout: Text(item: response, name: "stdout"),
                        Stderr: Text(item: response, name: "stderr"),
                        Status: response.GetProperty("status").GetInt32()
                    )),
            ],
            Stdout: Text(item: item, name: "stdout"),
            Status: item.GetProperty("status").GetInt32(),
            Calls:
            [
                .. item.GetProperty("calls")
                    .EnumerateArray()
                    .Select(call =>
                        string.Concat(call.EnumerateArray().Select(argument => Text(argument) + CALL_SEPARATOR))
                    ),
            ]
        );
    }

    public static async Task<string> StubAsync(CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);

        return Text(item: document.RootElement, name: "stub");
    }

    private static string Text(JsonElement item, string name)
    {
        return Text(item.GetProperty(name));
    }

    private static string Text(JsonElement value)
    {
        return value.GetString() ?? string.Empty;
    }

    private static Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        return EmbeddedFixture.LoadAsync(resourceName: RESOURCE_NAME, cancellationToken: cancellationToken);
    }
}
