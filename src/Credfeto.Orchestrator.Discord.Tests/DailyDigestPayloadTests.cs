using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class DailyDigestPayloadTests : TestBase
{
    private const string ZERO = """{"sessions":0,"denials":0,"stalled":0,"quits":0,"repos":[],"top_commands":[]}""";

    [Theory]
    [InlineData("""{"sessions":5}""", """{"sessions":3}""", "5 (+2 vs the day before)")]
    [InlineData("""{"sessions":3}""", """{"sessions":5}""", "3 (-2 vs the day before)")]
    [InlineData("""{"sessions":3}""", """{"sessions":3}""", "3 (no change vs the day before)")]
    [InlineData("""{"sessions":3}""", "{}", "3 (no record for the day before)")]
    [InlineData("""{"sessions":3}""", "null", "3 (no record for the day before)")]
    [InlineData("{}", "null", "null (no record for the day before)")]
    [InlineData("""{"sessions":"3"}""", "null", "3 (no record for the day before)")]
    [InlineData(
        """{"sessions":999999999999999}""",
        """{"sessions":-999999999999999}""",
        "999999999999999 (+1999999999999998 vs the day before)"
    )]
    public async Task EachTotalShowsItsChangeAsJqWorksItOutAsync(string sessions, string before, string expected)
    {
        JsonElement payload = await this.DigestAsync(summary: WithLists(sessions), previous: before);

        Assert.Equal(expected: expected, actual: FieldValue(payload: payload, name: "Sessions"));
    }

    [Theory]
    [InlineData("null", "No sessions were recorded for this day.")]
    [InlineData("false", "Agent sessions, permission denials and stalled sessions for this day.")]
    [InlineData(ZERO, "Agent sessions, permission denials and stalled sessions for this day.")]
    public async Task TheDescriptionSaysWhetherTheDayHasARecordAsync(string summary, string expected)
    {
        JsonElement payload = await this.DigestAsync(summary: summary, previous: "null");

        Assert.Equal(
            expected: expected,
            actual: payload.GetProperty("embeds")[0].GetProperty("description").GetString()
        );
        Assert.Equal(
            expected: "0 (no record for the day before)",
            actual: FieldValue(payload: payload, name: "Sessions")
        );
    }

    [Fact]
    public async Task OnlyTheFirstFifteenRepositoriesAreListedAsync()
    {
        string repos = string.Join(
            separator: ',',
            values: Enumerable
                .Range(start: 1, count: 20)
                .Select(index =>
                    string.Create(
                        CultureInfo.InvariantCulture,
                        $$"""{"repo":"o/r{{index}}","sessions":1,"denials":{{index}},"stalled":0}"""
                    )
                )
        );
        JsonElement payload = await this.DigestAsync(
            summary: Replaced(text: "\"repos\":[]", by: $"\"repos\":[{repos}]"),
            previous: "null"
        );

        string[] lines = FieldValue(payload: payload, name: "Per repository").Split('\n');
        Assert.Equal(expected: 15, actual: lines.Length);
        Assert.Equal(expected: "o/r15: 15 denial(s), 0 stalled, 1 session(s)", actual: lines[^1]);
    }

    [Theory]
    [InlineData("", "--summary is not JSON")]
    [InlineData("{\"sessions\": 1}", "--summary is not compact JSON as jq -c prints it")]
    [InlineData("""{"sessions":1,"sessions":2}""", "--summary is not compact JSON as jq -c prints it")]
    [InlineData("""{"sessions":1.5}""", "--summary holds a number that is not a plain integer, or nests too deep")]
    [InlineData("""{"sessions":1234567890123456}""", "--summary holds a number that is not a plain integer")]
    [InlineData("""{"sessions":-0}""", "--summary holds a number that is not a plain integer")]
    [InlineData("true", "the jq program fails on this summary")]
    [InlineData("[]", "the jq program fails on this summary")]
    [InlineData("""{"sessions":0}""", "the jq program fails on this summary")]
    [InlineData("""{"repos":{},"top_commands":[]}""", "the jq program fails on this summary")]
    [InlineData("""{"repos":[1],"top_commands":[]}""", "the jq program fails on this summary")]
    public async Task ASummaryJqMightReadOrAddUpDifferentlyIsRefusedAsync(string summary, string reason)
    {
        (int status, string output, string error) = await this.RunAsync(summary: summary, previous: "null");

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: discord: " + reason,
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData("false")]
    [InlineData("3")]
    [InlineData("\"x\"")]
    [InlineData("""{"sessions":"1"}""")]
    [InlineData("""{"sessions":true}""")]
    public async Task ADayBeforeJqFailsOnIsRefusedAsync(string previous)
    {
        (int status, string output, string error) = await this.RunAsync(
            summary: Replaced(text: "\"sessions\":0", by: "\"sessions\":2"),
            previous: previous
        );

        Assert.Equal(expected: DiscordCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.Equal(
            expected: "credfeto-orchestrator: discord: the jq program fails on this summary" + Environment.NewLine,
            actual: error
        );
    }

    // The day's totals, with empty repos and top_commands added
    private static string WithLists(string totals)
    {
        string rest = totals.Length == 2 ? string.Empty : totals[1..^1] + ",";

        return "{" + rest + "\"repos\":[],\"top_commands\":[]}";
    }

    // ZERO with one part replaced
    private static string Replaced(string text, string by)
    {
        return ZERO.Replace(oldValue: text, newValue: by, comparisonType: StringComparison.Ordinal);
    }

    private static string FieldValue(JsonElement payload, string name)
    {
        IEnumerable<JsonElement> fields = payload.GetProperty("embeds")[0].GetProperty("fields").EnumerateArray();

        return fields
            .Single(field => StringComparer.Ordinal.Equals(x: field.GetProperty("name").GetString(), y: name))
            .GetProperty("value")
            .GetString()
            ?? string.Empty;
    }

    private async Task<JsonElement> DigestAsync(string summary, string previous)
    {
        (int status, string output, string error) = await this.RunAsync(summary: summary, previous: previous);

        Assert.Equal(expected: string.Empty, actual: error);
        Assert.Equal(expected: 0, actual: status);

        using JsonDocument document = JsonDocument.Parse(output);

        return document.RootElement.Clone();
    }

    private async Task<(int Status, string Output, string Error)> RunAsync(string summary, string previous)
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using StringWriter output = new(CultureInfo.InvariantCulture);

        int status = await DiscordCommandRunner.RunAsync(
            args:
            [
                "discord",
                "payload",
                "daily-digest",
                "--owner",
                "org",
                "--day",
                "2026-10-04",
                "--summary",
                summary,
                "--previous",
                previous,
            ],
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (status, output.ToString(), error.ToString());
    }
}
