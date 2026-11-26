using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

// Every fixture case, asked through the state command line over the same state files: the query must print, return
// and leave behind what the shell function did, or refuse the cases marked "refuses"
[SupportedOSPlatform("linux")]
public sealed class StateParityTests : TestBase
{
    private const string OWNER = "owner";
    private const string PR = "PullRequest";
    private const string ISSUE = "Issue";

    // PULL_DURATION_MIN_SAMPLES's lib/globals default, for a case that does not set it
    private const string DEFAULT_MIN_SAMPLES = "5";

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return StateParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheQueryMatchesTheShellFunctionAsync(int index, string name)
    {
        CancellationToken cancellationToken = this.CancellationToken();
        StateParityCase parity = await StateParityFixture.CaseAsync(index: index, cancellationToken: cancellationToken);
        DirectoryInfo root = Directory.CreateTempSubdirectory("state-parity-");

        try
        {
            string state = root.FullName + "/state";
            Directory.CreateDirectory(state + "/" + OWNER + "/repo");
            await CreateFilesAsync(state: state, parity: parity, cancellationToken: cancellationToken);

            await using StringWriter error = new(CultureInfo.InvariantCulture);
            await using MemoryStream output = new();
            int status = await StateCommandRunner
                .CreateDefault()
                .RunAsync(
                    args: Arguments(state: state, parity: parity),
                    output: output,
                    error: error,
                    cancellationToken: cancellationToken
                );

            if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
            {
                Assert.Equal(expected: $"{name}: {StateCommandRunner.Refused}", actual: $"{name}: {status}");

                return;
            }

            if (status == StateQueries.Stale)
            {
                // is_owner_rate_limited removes the stale file and returns 1
                File.Delete(StatePaths.RateLimit(stateDirectory: state, owner: OWNER));
                status = StateQueries.NotFound;
            }

            Assert.Equal(
                expected: Describe(name: name, status: parity.Status, stdout: PrintfEscapes.Decode(parity.Stdout)),
                actual: Describe(name: name, status: status, stdout: output.ToArray())
            );
            Assert.Equal(expected: parity.Remaining, actual: Remaining(state));
            Assert.Equal(expected: string.Empty, actual: error.ToString());
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    private static string Describe(string name, int status, ReadOnlySpan<byte> stdout)
    {
        return $"{name}: status {status.ToString(CultureInfo.InvariantCulture)}, printed {Convert.ToHexString(stdout)}";
    }

    private static string Decoded(string text)
    {
        // An argument or name that is not UTF-8 reaches .NET with the bad bytes replaced, as on the command line
        return Encoding.UTF8.GetString(PrintfEscapes.Decode(text));
    }

    // The state files, built as test/oneshot-state-parity.bats builds them
    private static async Task CreateFilesAsync(
        string state,
        StateParityCase parity,
        CancellationToken cancellationToken
    )
    {
        foreach (StateParityFile file in parity.Files)
        {
            string path = state + "/" + Decoded(file.Path);
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? state);

            if (file.Directory)
            {
                Directory.CreateDirectory(path);
            }
            else if (file.Link is not null)
            {
                File.CreateSymbolicLink(path: path, pathToTarget: Decoded(file.Link));
            }
            else
            {
                await File.WriteAllBytesAsync(
                    path: path,
                    bytes: PrintfEscapes.Decode(file.Content),
                    cancellationToken: cancellationToken
                );
            }
        }
    }

    // What _state_tool_answers passes for each lib/state function
    private static IReadOnlyList<string> Arguments(string state, StateParityCase parity)
    {
        string session = state + "/" + OWNER + "/repo";
        IReadOnlyList<string> args = [.. parity.Arguments.Select(Decoded)];

        return parity.Function switch
        {
            "load_infra_failure_count" => Item(query: "infra-failures", session: session, type: args[0], id: args[1]),
            "load_env_unblock_attempts" => ["state", "env-unblock-attempts", "--session-dir", session, "--id", args[0]],
            "load_pr_invocation_counts" => Item(query: "invocations", session: session, type: PR, id: args[0]),
            "load_issue_invocation_counts" => Item(query: "invocations", session: session, type: ISSUE, id: args[0]),
            "issue_plan_block_marked" => Marker(session: session, type: ISSUE, id: args[0], kind: "plan-block"),
            "issue_blocked_replan_marked" => Marker(session: session, type: ISSUE, id: args[0], kind: "blocked-replan"),
            "background_stall_marked" => Marker(session: session, type: args[0], id: args[1], kind: "background-stall"),
            "load_last_diagnostic" => Item(query: "last-diagnostic", session: session, type: args[0], id: args[1]),
            "load_precheck_result" =>
            [
                "state",
                "precheck-result",
                "--session-dir",
                session,
                "--key",
                args[0],
                "--sha",
                args[1],
            ],
            "pull_duration_baseline" =>
            [
                "state",
                "pull-duration-baseline",
                "--state-dir",
                state,
                "--owner",
                OWNER,
                "--min-samples",
                parity.Globals.GetValueOrDefault(key: "PULL_DURATION_MIN_SAMPLES", defaultValue: DEFAULT_MIN_SAMPLES),
            ],
            "is_owner_rate_limited" => ["state", "rate-limit", "--state-dir", state, "--owner", OWNER],
            _ => ["state", "session-denials-summary", "--file", state + "/" + args[0]],
        };
    }

    private static IReadOnlyList<string> Item(string query, string session, string type, string id)
    {
        return ["state", query, "--session-dir", session, "--type", type, "--id", id];
    }

    private static IReadOnlyList<string> Marker(string session, string type, string id, string kind)
    {
        return [.. Item(query: "marker", session: session, type: type, id: id), "--kind", kind];
    }

    // Every path under the state directory, links not followed, as find . | LC_ALL=C sort lists them, each as printf
    // %b text
    private static IReadOnlyList<string> Remaining(string state)
    {
        List<string> paths = [];
        AddEntries(directory: new(state), relative: ".", paths: paths);

        return [.. paths.Select(Encoding.UTF8.GetBytes).Order(ByteOrder.Instance).Select(PrintfEscapes.Encode)];
    }

    private static void AddEntries(DirectoryInfo directory, string relative, List<string> paths)
    {
        foreach (FileSystemInfo entry in directory.EnumerateFileSystemInfos())
        {
            string path = relative + "/" + entry.Name;
            paths.Add(path);

            if (entry is DirectoryInfo subdirectory && entry.LinkTarget is null)
            {
                AddEntries(directory: subdirectory, relative: path, paths: paths);
            }
        }
    }
}
