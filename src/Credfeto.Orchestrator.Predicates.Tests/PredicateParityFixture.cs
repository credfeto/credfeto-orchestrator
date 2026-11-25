using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;
using Xunit;

namespace Credfeto.Orchestrator.Predicates.Tests;

// test/fixtures/predicates-parity.json, embedded: the cases test/oneshot-predicates-parity.bats checks
// the shell functions against. An argument that is a JSON string is passed as its text; any other
// JSON value is passed as jq -c prints it.
internal static class PredicateParityFixture
{
    private const string RESOURCE_NAME = "predicates-parity.json";

    public static async Task<TheoryData<int, string>> CaseNamesAsync()
    {
        using JsonDocument document = await LoadAsync(CancellationToken.None);
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            cases.Add(
                p1: index,
                p2: item.GetProperty("function").GetString() + ": " + item.GetProperty("name").GetString()
            );
            index++;
        }

        return cases;
    }

    public static async Task<PredicateParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];
        int perCommentMaximum = item.TryGetProperty(propertyName: "perCommentMax", value: out JsonElement per)
            ? per.GetInt32()
            : int.Parse(
                s: Setting(document: document, name: "PR_UNADDRESSED_COMMENT_MAX_CHARS"),
                provider: CultureInfo.InvariantCulture
            );

        return new(
            Name: item.GetProperty("name").GetString() ?? string.Empty,
            Function: item.GetProperty("function").GetString() ?? string.Empty,
            Arguments: [.. item.GetProperty("args").EnumerateArray().Select(Argument)],
            PerCommentMaximum: perCommentMaximum,
            Status: item.GetProperty("status").GetInt32(),
            Output: item.GetProperty("output").GetString() ?? string.Empty
        );
    }

    public static async Task<string> PatternAsync(string name, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);

        return document.RootElement.GetProperty("patterns").GetProperty(name).GetString() ?? string.Empty;
    }

    private static string Setting(JsonDocument document, string name)
    {
        return document.RootElement.GetProperty("settings").GetProperty(name).GetString() ?? string.Empty;
    }

    private static string Argument(JsonElement argument)
    {
        return argument.ValueKind == JsonValueKind.String
            ? argument.GetString() ?? string.Empty
            : JqFormatter.ToJson(JqParser.Parse(argument.GetRawText()));
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(PredicateParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
