using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

// The tool's side of test/fixtures/checks-reads-parity.json: each case's cfwf MCP server result run through
// "checks required-check-names" or "checks has-running-check-runs", as the shell switch asks them
public sealed class ChecksReadParityTests : TestBase
{
    public static Task<TheoryData<int, string>> RequiredCheckNameCasesAsync()
    {
        return ChecksReadParityFixture.CaseNamesAsync(ChecksReadParityFixture.RequiredCheckNames);
    }

    public static Task<TheoryData<int, string>> RunningCheckRunCasesAsync()
    {
        return ChecksReadParityFixture.CaseNamesAsync(ChecksReadParityFixture.HeadCommitRunningCheckRuns);
    }

    [Theory]
    [MemberData(nameof(RequiredCheckNameCasesAsync))]
    public async Task RequiredCheckNamesMatchTheShellVersionAsync(int index, string name)
    {
        JsonElement item = await ChecksReadParityFixture.ItemAsync(
            collection: ChecksReadParityFixture.RequiredCheckNames,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        FakeMcpToolCaller tools = Tools(item);
        string tool = Text(item: item, field: "tool");

        Result result = await this.RunAsync(
            tools,
            "checks",
            "required-check-names",
            "--repo",
            Text(item: item, field: "repo"),
            "--pr",
            Text(item: item, field: "pr")
        );

        int expectedExitCode = tool switch
        {
            "answers" => ExitCodes.Success,
            "fails" => ExitCodes.Failure,
            _ => ChecksReadCommandRunner.Refused,
        };
        string expectedOutput = StringComparer.Ordinal.Equals(x: tool, y: "answers")
            ? Text(item: item, field: "expected") + "\n"
            : string.Empty;

        Assert.Equal(
            expected: Describe(name: name, exitCode: expectedExitCode, output: expectedOutput),
            actual: Describe(name: name, exitCode: result.ExitCode, output: result.Output)
        );
        Assert.Equal(expected: "pr_view", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["repo"] = Text(item: item, field: "repo"),
                ["pr"] = Text(item: item, field: "pr"),
                ["fields"] = "[\"checks\"]",
                ["exactCheckNames"] = "true",
            },
            actual: tools.Arguments
        );
        Assert.Equal(expected: 0, actual: tools.ToolLists);
    }

    [Theory]
    [MemberData(nameof(RunningCheckRunCasesAsync))]
    public async Task RunningCheckRunsMatchTheShellVersionAsync(int index, string name)
    {
        JsonElement item = await ChecksReadParityFixture.ItemAsync(
            collection: ChecksReadParityFixture.HeadCommitRunningCheckRuns,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        FakeMcpToolCaller tools = Tools(item);
        string repository = Text(item: item, field: "repo");
        string sha = Text(item: item, field: "sha");
        int toolStatus = item.GetProperty("toolStatus").GetInt32();

        Result result = await this.RunAsync(
            tools,
            "checks",
            "has-running-check-runs",
            "--repo",
            repository,
            "--sha",
            sha
        );

        Assert.Equal(
            expected: Describe(name: name, exitCode: toolStatus, output: string.Empty),
            actual: Describe(name: name, exitCode: result.ExitCode, output: result.Output)
        );

        if (repository.Length == 0 || sha.Length == 0)
        {
            // The shell's guard: nothing is asked
            Assert.Equal(expected: 0, actual: tools.ToolLists);
            Assert.Null(tools.Tool);

            return;
        }

        Assert.Equal(expected: 1, actual: tools.ToolLists);

        if (
            toolStatus == ChecksReadCommandRunner.Refused
            || item.TryGetProperty(propertyName: "toolsError", value: out _)
        )
        {
            Assert.Null(tools.Tool);

            return;
        }

        Assert.Equal(expected: "commit_check_runs", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal) { ["repo"] = repository, ["sha"] = sha },
            actual: tools.Arguments
        );
    }

    private static FakeMcpToolCaller Tools(JsonElement item)
    {
        return new(
            result: item.TryGetProperty(propertyName: "mcp", value: out JsonElement mcp) ? mcp.GetRawText() : null,
            error: item.TryGetProperty(propertyName: "mcpError", value: out JsonElement error)
                ? error.GetString()
                : null,
            tools: item.TryGetProperty(propertyName: "tools", value: out JsonElement listed)
                ? [.. listed.EnumerateArray().Select(tool => tool.GetString() ?? string.Empty)]
                : null,
            toolsError: item.TryGetProperty(propertyName: "toolsError", value: out JsonElement toolsError)
                ? toolsError.GetString()
                : null
        );
    }

    private static string Text(JsonElement item, string field)
    {
        return item.GetProperty(field).GetString() ?? string.Empty;
    }

    private static string Describe(string name, int exitCode, string output)
    {
        return name + ": exit " + exitCode.ToString(CultureInfo.InvariantCulture) + ", " + output;
    }

    private async Task<Result> RunAsync(FakeMcpToolCaller tools, params string[] args)
    {
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FakeFileContentReader(),
            github: new GitHubReader(tools),
            discovery: DiscoveryFakes.NotExpected(new GitHubReader(tools))
        );
        using MemoryStream stdin = new();
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await runner.RunAsync(
            args: args,
            input: stdin,
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return new(ExitCode: exitCode, Output: output.ToString(), Error: error.ToString());
    }
}
