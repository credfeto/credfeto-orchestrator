using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

// test/fixtures/state-writes-parity.json, embedded: the golden cases test/oneshot-state-writes-parity.bats checks the
// shell version against
internal static class StateWritesParityFixture
{
    private const string RESOURCE_NAME = "state-writes-parity.json";
    private const string DEFAULT_UMASK = "022";
    private const int OCTAL = 8;

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

    public static async Task<StateWritesParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];

        return new(
            Function: Text(item: item, name: "function"),
            Arguments: [.. item.GetProperty("args").EnumerateArray().Select(Text)],
            Umask: Convert.ToInt32(value: Optional(item: item, name: "umask") ?? DEFAULT_UMASK, fromBase: OCTAL),
            SessionDirectory: !(
                item.TryGetProperty(propertyName: "no_session_dir", value: out JsonElement bare) && bare.GetBoolean()
            ),
            Files: [.. item.GetProperty("files").EnumerateArray().Select(ParseFile)],
            Globals: Globals(item),
            Tool: Text(item: item, name: "tool"),
            Stdout: Text(item: item, name: "stdout"),
            Status: item.GetProperty("status").GetInt32(),
            Left: [.. item.GetProperty("left").EnumerateArray().Select(Entry)]
        );
    }

    // A left entry as StateWritesTree.ListAsync writes it: type, path, mode, and the content or link target
    private static string Entry(JsonElement entry)
    {
        string type = Text(item: entry, name: "type");
        string detail = Optional(item: entry, name: "content") ?? Optional(item: entry, name: "target") ?? string.Empty;

        return string.Join(
            separator: ' ',
            Text(item: entry, name: "type"),
            Text(item: entry, name: "path"),
            Optional(item: entry, name: "mode") ?? string.Empty,
            StringComparer.Ordinal.Equals(x: type, y: "d") ? string.Empty : detail
        );
    }

    private static StateWritesParityFile ParseFile(JsonElement file)
    {
        return new(
            Path: Text(item: file, name: "path"),
            Directory: file.TryGetProperty(propertyName: "dir", value: out JsonElement directory)
                && directory.GetBoolean(),
            Link: Optional(item: file, name: "link"),
            HardLink: Optional(item: file, name: "hardlink"),
            Content: Optional(item: file, name: "content") ?? string.Empty,
            Mode: Optional(item: file, name: "mode") ?? string.Empty
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

    private static string? Optional(JsonElement item, string name)
    {
        return item.TryGetProperty(propertyName: name, value: out JsonElement value) ? Text(value) : null;
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
        await using Stream stream = typeof(StateWritesParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }

    public static string Mode(uint permissions)
    {
        return Convert.ToString(value: permissions, toBase: OCTAL).PadLeft(totalWidth: 4, paddingChar: '0');
    }

    public static UnixFileMode ParseMode(string mode)
    {
        return (UnixFileMode)Convert.ToInt32(value: mode, fromBase: OCTAL);
    }

    public static string Invariant(int value)
    {
        return value.ToString(CultureInfo.InvariantCulture);
    }
}
