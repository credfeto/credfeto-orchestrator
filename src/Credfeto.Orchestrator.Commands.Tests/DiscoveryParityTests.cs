using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

// Runs the tool on every case of test/fixtures/discovery-parity.json and maps its exit code as the lib/github and
// lib/github-health switch branches do, so the status compared is the shell function's return code
public sealed class DiscoveryParityTests : TestBase
{
    private const string STATUS_URL = "https://status.example/api/v2/summary.json";

    public static Task<TheoryData<int, string>> GitHubHealthCasesAsync()
    {
        return DiscoveryParityFixture.CaseNamesAsync(DiscoveryParityFixture.GitHubHealth);
    }

    public static Task<TheoryData<int, string>> PriorityCasesAsync()
    {
        return DiscoveryParityFixture.CaseNamesAsync(DiscoveryParityFixture.Priorities);
    }

    public static Task<TheoryData<int, string>> TrustedLoginsCasesAsync()
    {
        return DiscoveryParityFixture.CaseNamesAsync(DiscoveryParityFixture.TrustedLogins);
    }

    [Theory]
    [MemberData(nameof(GitHubHealthCasesAsync))]
    public async Task TheGitHubIncidentMatchesTheShellVersionAsync(int index, string name)
    {
        JsonElement parity = await DiscoveryParityFixture.CaseAsync(
            collection: DiscoveryParityFixture.GitHubHealth,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        List<string> args = ["discovery", "github-incident", "--url", STATUS_URL];
        await this.AddListAsync(args: args, option: "--component", list: "components");
        await this.AddListAsync(args: args, option: "--serious-impact", list: "seriousImpacts");
        await this.AddListAsync(args: args, option: "--outage-status", list: "outageStatuses");
        FakeUrlReader urls = new(DiscoveryParityFixture.OptionalText(element: parity, name: "body"));

        Result result = await this.RunAsync(urls: urls, mcp: Unused(), args: args);

        // github_incident_open: 0 and 3 print the tool's line, 4 is no incident, anything else fails open
        int status = result.ExitCode switch
        {
            0 or 3 when result.Output.Length != 0 => result.ExitCode,
            4 => 1,
            _ => 2,
        };
        AssertShellResult(
            name: name,
            parity: parity,
            status: status,
            output: status is 0 or 3 ? result.Output : string.Empty
        );
        Assert.Equal(expected: STATUS_URL, actual: Assert.Single(urls.Requests).Url.OriginalString);
    }

    [Theory]
    [MemberData(nameof(PriorityCasesAsync))]
    public async Task ThePrioritiesMatchTheShellVersionAsync(int index, string name)
    {
        JsonElement parity = await DiscoveryParityFixture.CaseAsync(
            collection: DiscoveryParityFixture.Priorities,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        string feed = await DiscoveryParityFixture.PriorityFeedUrlAsync(this.CancellationToken());
        List<string> args = ["discovery", "priorities", "--url", feed];
        string? user = DiscoveryParityFixture.OptionalText(element: parity, name: "user");

        if (user is not null)
        {
            args.AddRange(["--user", user]);
        }

        args.AddRange(["--attempts", parity.GetProperty("attempts").GetRawText(), "--delay-secs", "0"]);
        FakeUrlReader urls = new(DiscoveryParityFixture.OptionalTexts(parity.GetProperty("responses")));

        Result result = await this.RunAsync(urls: urls, mcp: Unused(), args: args);

        // fetch_all_priorities: 0 prints the tool's output, 3 is a parse failure (2), anything else unreachable (1)
        int status = result.ExitCode switch
        {
            0 => 0,
            3 => 2,
            _ => 1,
        };
        AssertShellResult(
            name: name,
            parity: parity,
            status: status,
            output: status == 0 ? result.Output : string.Empty
        );
        Assert.Equal(expected: parity.GetProperty("requests").GetInt32(), actual: urls.Requests.Count);
        Assert.All(urls.Requests, request =>
            Assert.Equal(
                expected: DiscoveryParityFixture.Text(element: parity, name: "url"),
                actual: request.Url.OriginalString
            )
        );
    }

    [Theory]
    [MemberData(nameof(TrustedLoginsCasesAsync))]
    public async Task TheTrustedLoginsMatchTheShellVersionAsync(int index, string name)
    {
        JsonElement parity = await DiscoveryParityFixture.CaseAsync(
            collection: DiscoveryParityFixture.TrustedLogins,
            index: index,
            cancellationToken: this.CancellationToken()
        );
        string repository = DiscoveryParityFixture.Text(element: parity, name: "repo");
        ScriptedMcpToolCaller mcp = new(
            failures: parity.GetProperty("failures").GetInt32(),
            result: CollaboratorsResult(
                repository: repository,
                logins: DiscoveryParityFixture.Texts(parity.GetProperty("collaborators"))
            )
        );
        string[] args =
        [
            "discovery",
            "trusted-logins",
            "--repo",
            repository,
            "--owner",
            DiscoveryParityFixture.Text(element: parity, name: "owner"),
            "--whitelist",
            DiscoveryParityFixture.Text(element: parity, name: "whitelist"),
            "--creator",
            DiscoveryParityFixture.Text(element: parity, name: "creator"),
            "--attempts",
            parity.GetProperty("attempts").GetRawText(),
            "--delay-secs",
            "0",
        ];

        Result result = await this.RunAsync(urls: new(), mcp: mcp, args: args);

        // get_trusted_logins: only a successful, non-empty answer is trusted
        int status = result.ExitCode == 0 && result.Output.Length != 0 ? 0 : 1;
        AssertShellResult(
            name: name,
            parity: parity,
            status: status,
            output: status == 0 ? result.Output : string.Empty
        );
        Assert.Equal(expected: parity.GetProperty("requests").GetInt32(), actual: mcp.Calls);
        Assert.Equal(expected: "repo_collaborators", actual: mcp.Tool);
        Assert.Equal(expected: repository, actual: mcp.Arguments?["repo"]);
    }

    private static void AssertShellResult(string name, JsonElement parity, int status, string output)
    {
        Assert.Equal(
            expected: Describe(
                name: name,
                status: parity.GetProperty("status").GetInt32(),
                output: DiscoveryParityFixture.Text(element: parity, name: "output")
            ),
            actual: Describe(name: name, status: status, output: output)
        );
    }

    private static string Describe(string name, int status, string output)
    {
        return $"{name}: {status} {Quote(output)}";
    }

    private static string CollaboratorsResult(string repository, IReadOnlyList<string> logins)
    {
        return "{\"repository\":"
            + Quote(repository)
            + ",\"collaborators\":["
            + string.Join(
                separator: ',',
                values: logins.Select(static login => "{\"login\":" + Quote(login) + ",\"role\":\"write\"}")
            )
            + "]}";
    }

    private static string Quote(string text)
    {
        return JqFormatter.ToJson(JqValue.FromString(text));
    }

    private static ScriptedMcpToolCaller Unused()
    {
        return new(failures: int.MaxValue, result: string.Empty);
    }

    private async Task AddListAsync(List<string> args, string option, string list)
    {
        IReadOnlyList<string> values = await DiscoveryParityFixture.GitHubHealthListAsync(
            name: list,
            cancellationToken: this.CancellationToken()
        );

        foreach (string value in values)
        {
            args.AddRange([option, value]);
        }
    }

    // What the shell's command substitution keeps: the output without its trailing newlines
    private async Task<Result> RunAsync(FakeUrlReader urls, ScriptedMcpToolCaller mcp, IReadOnlyList<string> args)
    {
        GitHubReader github = new(mcp);
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FakeFileContentReader(),
            github: github,
            discovery: DiscoveryFakes.Runner(urls: urls, delay: new(), github: github)
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

        return new(ExitCode: exitCode, Output: output.ToString().TrimEnd('\n'), Error: error.ToString());
    }
}
