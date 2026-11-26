using System;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// Every fixture case, its result file written as the bats file writes it: the read must print what the shell
// function's jq printed, with status 0, or refuse the cases marked "refuses"
public sealed class ClaudeResultParityTests : TestBase
{
    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return ClaudeResultParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheReadMatchesTheShellFunctionAsync(int index, string name)
    {
        CancellationToken cancellationToken = this.CancellationToken();
        ClaudeResultParityCase parity = await ClaudeResultParityFixture.CaseAsync(
            index: index,
            cancellationToken: cancellationToken
        );
        using ResultFiles files = new();
        string resultFile = await files.WriteAsync(
            content: PrintfEscapes.Decode(parity.Result),
            cancellationToken: cancellationToken
        );

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
        {
            await Assert.ThrowsAsync<PodmanRefusedException>(() =>
                ReadAsync(function: parity.Function, resultFile: resultFile, cancellationToken: cancellationToken)
            );

            return;
        }

        PodmanResult result = await ReadAsync(
            function: parity.Function,
            resultFile: resultFile,
            cancellationToken: cancellationToken
        );

        Assert.Equal(
            expected: Describe(name: name, status: parity.Status, stdout: PrintfEscapes.Decode(parity.Stdout)),
            actual: Describe(name: name, status: result.ExitCode, stdout: result.Output.Span)
        );
    }

    private static string Describe(string name, int status, ReadOnlySpan<byte> stdout)
    {
        return $"{name}: status {status.ToString(CultureInfo.InvariantCulture)}, printed {Convert.ToHexString(stdout)}";
    }

    private static async Task<PodmanResult> ReadAsync(
        string function,
        string resultFile,
        CancellationToken cancellationToken
    )
    {
        ClaudeResultQueries queries = new();

        return function switch
        {
            "claude_result_permission_denials_summary" => await queries.DenialsSummaryAsync(
                resultFile: resultFile,
                cancellationToken: cancellationToken
            ),
            "claude_result_denied_command_names" => await queries.DeniedCommandNamesAsync(
                resultFile: resultFile,
                cancellationToken: cancellationToken
            ),
            _ => throw new InvalidOperationException("Unknown function " + function),
        };
    }
}
