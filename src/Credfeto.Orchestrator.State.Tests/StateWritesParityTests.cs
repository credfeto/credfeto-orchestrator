using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

// Every fixture case, written through the state command line over the same files: the write must print, return and
// leave behind what the shell function did, or, for the cases marked "refuses", refuse (or fail) and leave every file
// as it was
[SupportedOSPlatform("linux")]
[Collection(UmaskSerial.Name)]
public sealed class StateWritesParityTests : TestBase
{
    private const string PR = "PullRequest";
    private const string ISSUE = "Issue";

    // The umask test/oneshot-state-writes-parity.bats builds the files under
    private const int BUILD_UMASK = 0x12;

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return StateWritesParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheWriteMatchesTheShellFunctionAsync(int index, string name)
    {
        CancellationToken cancellationToken = this.CancellationToken();
        StateWritesParityCase parity = await StateWritesParityFixture.CaseAsync(
            index: index,
            cancellationToken: cancellationToken
        );
        int umask = NativeMethods.SetUmask(BUILD_UMASK);
        DirectoryInfo root = Directory.CreateTempSubdirectory("state-writes-parity-");

        try
        {
            string state = root.FullName + "/state";
            await StateWritesTree.CreateAsync(state: state, parity: parity, cancellationToken: cancellationToken);
            IReadOnlyList<string> before = await StateWritesTree.ListAsync(
                state: state,
                cancellationToken: cancellationToken
            );

            (int status, string printed, string error) = await RunAsync(
                state: state,
                parity: parity,
                cancellationToken: cancellationToken
            );

            Assert.Equal(expected: $"{name}: printed {parity.Stdout}", actual: $"{name}: printed {printed}");

            if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
            {
                Assert.Contains(expected: status, collection: [StateCommandRunner.Refused, StateCommandRunner.Failed]);
                Assert.Equal(
                    expected: before,
                    actual: await StateWritesTree.ListAsync(state: state, cancellationToken: cancellationToken)
                );

                return;
            }

            Assert.Equal(
                expected: $"{name}: status {StateWritesParityFixture.Invariant(parity.Status)}",
                actual: $"{name}: status {StateWritesParityFixture.Invariant(status)}"
            );
            Assert.Equal(
                expected: parity.Left,
                actual: await StateWritesTree.ListAsync(state: state, cancellationToken: cancellationToken)
            );
            Assert.Equal(expected: string.Empty, actual: error);
        }
        finally
        {
            NativeMethods.SetUmask(umask);
            StateWritesTree.Remove(root);
        }
    }

    // The write under the case's umask, as the tool inherits bash's
    private static async Task<(int Status, string Printed, string Error)> RunAsync(
        string state,
        StateWritesParityCase parity,
        CancellationToken cancellationToken
    )
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using MemoryStream output = new();
        byte[] input = StringComparer.Ordinal.Equals(x: parity.Function, y: "save_last_diagnostic")
            ? [.. PrintfEscapes.Decode(parity.Arguments[2]), (byte)'\n']
            : [];
        StateCommandRunner runner = new(queries: new StateQueries(TimeProvider.System), input: () =>
            new MemoryStream(input)
        );

        NativeMethods.SetUmask(parity.Umask);

        try
        {
            int status = await runner.RunAsync(
                args: Arguments(state: state, parity: parity),
                output: output,
                error: error,
                cancellationToken: cancellationToken
            );

            return (status, PrintfEscapes.Encode(output.ToArray()), error.ToString());
        }
        finally
        {
            NativeMethods.SetUmask(BUILD_UMASK);
        }
    }

    // What _state_tool_wrote passes for each lib/state function
    private static IReadOnlyList<string> Arguments(string state, StateWritesParityCase parity)
    {
        string session = state + "/owner/repo";
        IReadOnlyList<string> args = [.. parity.Arguments.Select(StateWritesTree.Decoded)];

        return parity.Function switch
        {
            "save_infra_failure_count" =>
            [
                .. Item(query: "save-infra-failures", session: session, type: args[0], id: args[1]),
                "--count",
                args[2],
            ],
            "save_pr_invocation_counts" => Invocations(session: session, type: PR, args: args),
            "save_issue_invocation_counts" => Invocations(session: session, type: ISSUE, args: args),
            "save_env_unblock_attempts" =>
            [
                "state",
                "save-env-unblock-attempts",
                "--session-dir",
                session,
                "--id",
                args[0],
                "--total",
                args[1],
            ],
            "save_rate_limit" =>
            [
                "state",
                "save-rate-limit",
                "--state-dir",
                state,
                "--owner",
                parity.Globals.GetValueOrDefault(key: "OWNER", defaultValue: "owner"),
                "--reset",
                args[0],
            ],
            "save_precheck_result" =>
            [
                "state",
                "save-precheck-result",
                "--session-dir",
                session,
                "--key",
                args[0],
                "--sha",
                args[1],
                "--status",
                args[2],
            ],
            _ => Item(query: "save-last-diagnostic", session: session, type: args[0], id: args[1]),
        };
    }

    private static IReadOnlyList<string> Invocations(string session, string type, IReadOnlyList<string> args)
    {
        return
        [
            .. Item(query: "save-invocations", session: session, type: type, id: args[0]),
            "--total",
            args[1],
            "--idle",
            args[2],
        ];
    }

    private static IReadOnlyList<string> Item(string query, string session, string type, string id)
    {
        return ["state", query, "--session-dir", session, "--type", type, "--id", id];
    }
}
