using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

// test/fixtures/checks-reads-parity.json, embedded: the golden cases test/oneshot-checks-reads-parity.bats checks the
// shell version against. Each case holds the gh response the shell reads, the cfwf MCP server result the tool reads,
// what the tool does with it and what the shell function prints or returns.
internal static class ChecksReadParityFixture
{
    public const string RequiredCheckNames = "requiredCheckNames";
    public const string HeadCommitRunningCheckRuns = "headCommitRunningCheckRuns";

    private const string RESOURCE_NAME = "checks-reads-parity.json";

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

    // One case of a collection, detached from the fixture document so it outlives it
    public static async Task<JsonElement> ItemAsync(string collection, int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);

        return document.RootElement.GetProperty(collection)[index].Clone();
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(ChecksReadParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
