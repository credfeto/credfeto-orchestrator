using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

// test/fixtures/state-parity.json, embedded: the golden cases test/oneshot-state-parity.bats checks the shell version
// against
internal static class StateParityFixture
{
    private const string RESOURCE_NAME = "state-parity.json";

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

    public static async Task<StateParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];

        return new(
            Function: Text(item: item, name: "function"),
            Arguments: [.. item.GetProperty("args").EnumerateArray().Select(Text)],
            Files: [.. item.GetProperty("files").EnumerateArray().Select(ParseFile)],
            Globals: Globals(item),
            Tool: Text(item: item, name: "tool"),
            Stdout: Text(item: item, name: "stdout"),
            Status: item.GetProperty("status").GetInt32(),
            Remaining: [.. item.GetProperty("remaining").EnumerateArray().Select(Text)]
        );
    }

    private static StateParityFile ParseFile(JsonElement file)
    {
        return new(
            Path: Text(item: file, name: "path"),
            Directory: file.TryGetProperty(propertyName: "dir", value: out JsonElement directory)
                && directory.GetBoolean(),
            Link: file.TryGetProperty(propertyName: "link", value: out JsonElement link) ? Text(link) : null,
            Content: file.TryGetProperty(propertyName: "content", value: out JsonElement content)
                ? Text(content)
                : string.Empty
        );
    }

    private static IReadOnlyDictionary<string, string> Globals(JsonElement item)
    {
        Dictionary<string, string> globals = [with(StringComparer.Ordinal)];

        if (item.TryGetProperty(propertyName: "globals", value: out JsonElement values))
        {
            foreach (JsonProperty value in values.EnumerateObject())
            {
                globals[value.Name] = Text(value.Value);
            }
        }

        return globals;
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
        await using Stream stream = typeof(StateParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
