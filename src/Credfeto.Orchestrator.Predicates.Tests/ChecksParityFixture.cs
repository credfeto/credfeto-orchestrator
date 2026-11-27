using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;
using Xunit;

namespace Credfeto.Orchestrator.Predicates.Tests;

// test/fixtures/checks-parity.json, embedded: the cases test/oneshot-checks-parity.bats checks the shell functions
// against, in each locale. An argument that is a JSON string is passed as its text; any other JSON value is passed
// as jq -c prints it.
internal static class ChecksParityFixture
{
    private const string RESOURCE_NAME = "checks-parity.json";

    public static async Task<TheoryData<int, string>> CaseNamesAsync()
    {
        IReadOnlyList<ChecksParityCase> cases = await ReadCasesAsync(CancellationToken.None);
        TheoryData<int, string> names = [];

        for (int index = 0; index < cases.Count; index++)
        {
            names.Add(p1: index, p2: cases[index].Function + ": " + cases[index].Name);
        }

        return names;
    }

    public static async Task<ChecksParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        IReadOnlyList<ChecksParityCase> cases = await ReadCasesAsync(cancellationToken);

        return cases[index];
    }

    private static async Task<IReadOnlyList<ChecksParityCase>> ReadCasesAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(ChecksParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);
        using JsonDocument document = await JsonDocument.ParseAsync(
            utf8Json: stream,
            cancellationToken: cancellationToken
        );

        return [.. document.RootElement.GetProperty("cases").EnumerateArray().Select(ToCase)];
    }

    private static ChecksParityCase ToCase(JsonElement item)
    {
        return new(
            Name: item.GetProperty("name").GetString() ?? string.Empty,
            Function: item.GetProperty("function").GetString() ?? string.Empty,
            Arguments: [.. item.GetProperty("args").EnumerateArray().Select(ToArgument)],
            Refused: StringComparer.Ordinal.Equals(x: item.GetProperty("tool").GetString(), y: "refuses"),
            Status: item.GetProperty("status").GetInt32(),
            Output: item.GetProperty("output").GetString() ?? string.Empty
        );
    }

    private static string ToArgument(JsonElement argument)
    {
        return argument.ValueKind == JsonValueKind.String
            ? argument.GetString() ?? string.Empty
            : JqFormatter.ToJson(JqParser.Parse(argument.GetRawText()));
    }
}
