using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Git.Tests;

// test/fixtures/git-parity.json, embedded: the scenario scripts that build throwaway repositories, and the golden cases
// test/oneshot-git-parity.bats checks the shell version against
internal static class GitParityFixture
{
    public const string ROOT_PLACEHOLDER = "@ROOT@";

    private const string RESOURCE_NAME = "git-parity.json";

    // The cases the tool is asked: the others are answered by bash before it would be
    public static async Task<TheoryData<int, string>> ToolCaseNamesAsync()
    {
        using JsonDocument document = await LoadAsync(CancellationToken.None);
        TheoryData<int, string> cases = [];
        int index = 0;

        foreach (JsonElement item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            if (!StringComparer.Ordinal.Equals(x: Text(item: item, name: "tool"), y: "not-called"))
            {
                cases.Add(p1: index, p2: Text(item: item, name: "name"));
            }

            index++;
        }

        return cases;
    }

    public static async Task<GitParityCase> CaseAsync(int index, CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        JsonElement item = document.RootElement.GetProperty("cases")[index];

        return new(
            Function: Text(item: item, name: "function"),
            Scenario: Text(item: item, name: "scenario"),
            Repository: Text(item: item, name: "repo"),
            Arguments:
            [
                .. item.GetProperty("args").EnumerateArray().Select(argument => argument.GetString() ?? string.Empty),
            ],
            Tool: Text(item: item, name: "tool"),
            Stdout: Text(item: item, name: "stdout"),
            Status: item.GetProperty("status").GetInt32()
        );
    }

    // The fixture's environment: its variables set, and those under unset removed (null)
    public static async Task<IReadOnlyDictionary<string, string?>> EnvironmentAsync(CancellationToken cancellationToken)
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        Dictionary<string, string?> environment = [with(StringComparer.Ordinal)];

        foreach (JsonElement name in document.RootElement.GetProperty("unset").EnumerateArray())
        {
            environment[name.GetString() ?? string.Empty] = null;
        }

        foreach (JsonProperty variable in document.RootElement.GetProperty("environment").EnumerateObject())
        {
            environment[variable.Name] = variable.Value.GetString();
        }

        return environment;
    }

    // Each scenario's name and the script that builds it: the prelude, then the scenario's setup
    public static async Task<IReadOnlyList<KeyValuePair<string, string>>> ScenarioScriptsAsync(
        CancellationToken cancellationToken
    )
    {
        using JsonDocument document = await LoadAsync(cancellationToken);
        string prelude = Text(item: document.RootElement, name: "prelude");

        return
        [
            .. document
                .RootElement.GetProperty("scenarios")
                .EnumerateArray()
                .Select(scenario => new KeyValuePair<string, string>(
                    key: Text(item: scenario, name: "name"),
                    value: prelude + "\n" + Text(item: scenario, name: "setup")
                )),
        ];
    }

    private static string Text(JsonElement item, string name)
    {
        return item.GetProperty(name).GetString() ?? string.Empty;
    }

    private static async Task<JsonDocument> LoadAsync(CancellationToken cancellationToken)
    {
        await using Stream stream = typeof(GitParityFixture).Assembly.GetManifestResourceStream(RESOURCE_NAME)
            ?? throw new InvalidOperationException("Missing embedded resource " + RESOURCE_NAME);

        return await JsonDocument.ParseAsync(utf8Json: stream, cancellationToken: cancellationToken);
    }
}
