using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

// test/fixtures/prompts-parity.json and prompts-pr-parity.json, embedded: the golden cases
// test/oneshot-prompts-parity.bats checks the shell version against. Each case holds the prompt kind, the name=value
// records lib/prompts sends the tool and what the shell function prints for them
internal static class PromptParityFixture
{
    public const string IssueClaudeMd = "issueClaudeMd";
    public const string PullRequestClaudeMd = "pullRequestClaudeMd";
    public const string LaunchPrompts = "launchPrompts";
    public const string PrecheckSections = "precheckSections";
    public const string CheckLength = "checkLength";

    public static async Task<TheoryData<int, string>> CaseNamesAsync(string collection)
    {
        using JsonDocument document = await LoadAsync(
            collection: collection,
            cancellationToken: CancellationToken.None
        );
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty(collection).EnumerateArray())
        {
            cases.Add(p1: index, p2: Text(item: item, name: "name"));
            index++;
        }

        return cases;
    }

    public static async Task<PromptParityCase> CaseAsync(
        string collection,
        int index,
        CancellationToken cancellationToken
    )
    {
        using JsonDocument document = await LoadAsync(collection: collection, cancellationToken: cancellationToken);
        JsonElement item = document.RootElement.GetProperty(collection)[index];

        return new(
            Kind: Text(item: item, name: "kind"),
            Refuses: StringComparer.Ordinal.Equals(x: Text(item: item, name: "tool"), y: "refuses"),
            Records: Records(item.GetProperty("records")),
            Expected: Text(item: item, name: "expected")
        );
    }

    public static async Task<PromptLengthParityCase> LengthCaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(collection: CheckLength, cancellationToken: cancellationToken);
        JsonElement item = document.RootElement.GetProperty(CheckLength)[index];

        return new(
            Locale: Text(item: item, name: "locale"),
            Max: Text(item: item, name: "max"),
            Prompt: Convert.FromBase64String(Text(item: item, name: "promptBase64")),
            Length: Text(item: item, name: "length"),
            TooLong: item.GetProperty("tooLong").GetBoolean()
        );
    }

    // Each record as lib/prompts sends it: name=value then a NUL byte, a list once per entry
    private static byte[] Records(in JsonElement records)
    {
        StringBuilder text = new();

        foreach (JsonProperty record in records.EnumerateObject())
        {
            if (record.Value.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement entry in record.Value.EnumerateArray())
                {
                    text.Append(record.Name).Append('=').Append(entry.GetString()).Append('\0');
                }
            }
            else
            {
                text.Append(record.Name).Append('=').Append(record.Value.GetString()).Append('\0');
            }
        }

        return Encoding.UTF8.GetBytes(text.ToString());
    }

    private static string Text(in JsonElement item, string name)
    {
        return item.GetProperty(name).GetString() ?? string.Empty;
    }

    private static async Task<JsonDocument> LoadAsync(string collection, CancellationToken cancellationToken)
    {
        string resource = StringComparer.Ordinal.Equals(x: collection, y: PullRequestClaudeMd)
            ? "prompts-pr-parity.json"
            : "prompts-parity.json";
        await using Stream stream = typeof(PromptParityFixture).Assembly.GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException("Missing embedded resource " + resource);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
