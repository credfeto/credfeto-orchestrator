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

namespace Credfeto.Orchestrator.Podman.Tests;

// Every fixture case, run through the podman command line as the fixture's stub: the query must print and return what
// the shell function did and make the same podman calls, or refuse the cases marked "refuses"
[SupportedOSPlatform("linux")]
public sealed class PodmanParityTests : TestBase, IClassFixture<PodmanParityStub>
{
    private readonly PodmanParityStub _stub;

    public PodmanParityTests(PodmanParityStub stub)
    {
        this._stub = stub;
    }

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return PodmanParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheQueryMatchesTheShellFunctionAsync(int index, string name)
    {
        CancellationToken cancellationToken = this.CancellationToken();
        PodmanParityCase parity = await PodmanParityFixture.CaseAsync(
            index: index,
            cancellationToken: cancellationToken
        );
        string directory = this._stub.NewCaseDirectory();
        await ScriptResponsesAsync(directory: directory, parity: parity, cancellationToken: cancellationToken);
        PodmanQueries queries = new(
            new PodmanProcessRunner(
                executable: this._stub.Executable,
                workingDirectory: directory,
                environment: new Dictionary<string, string?>(StringComparer.Ordinal)
                {
                    ["PODMAN_PARITY_DIR"] = directory,
                },
                discardErrors: true
            )
        );

        // An argument that is not UTF-8 reaches .NET with the bad bytes replaced, as it would on the command line
        string argument = Encoding.UTF8.GetString(PrintfEscapes.Decode(parity.Argument));

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
        {
            await Assert.ThrowsAsync<PodmanRefusedException>(() =>
                AskAsync(queries: queries, function: parity.Function, argument: argument, cancellationToken)
            );

            return;
        }

        PodmanResult result = await AskAsync(
            queries: queries,
            function: parity.Function,
            argument: argument,
            cancellationToken: cancellationToken
        );

        Assert.Equal(
            expected: Describe(name: name, status: parity.Status, stdout: PrintfEscapes.Decode(parity.Stdout)),
            actual: Describe(name: name, status: result.ExitCode, stdout: result.Output.Span)
        );
        Assert.Equal(
            expected: parity.Calls,
            actual: await CallsAsync(directory: directory, cancellationToken: cancellationToken)
        );
    }

    private static string Describe(string name, int status, ReadOnlySpan<byte> stdout)
    {
        return $"{name}: status {status.ToString(CultureInfo.InvariantCulture)}, printed {Convert.ToHexString(stdout)}";
    }

    // The files the stub answers from, written as test/oneshot-podman-parity.bats writes them
    private static async Task ScriptResponsesAsync(
        string directory,
        PodmanParityCase parity,
        CancellationToken cancellationToken
    )
    {
        for (int index = 0; index < parity.Responses.Count; index++)
        {
            PodmanParityResponse response = parity.Responses[index];
            string prefix = Path.Combine(
                path1: directory,
                path2: "response-" + index.ToString(CultureInfo.InvariantCulture)
            );
            byte[] arguments =
            [
                .. response.Arguments.SelectMany(argument => PrintfEscapes.Decode(argument).Append((byte)0)),
            ];
            await File.WriteAllBytesAsync(
                path: prefix + ".args",
                bytes: arguments,
                cancellationToken: cancellationToken
            );
            await File.WriteAllTextAsync(path: prefix + ".stdout", contents: response.Stdout, cancellationToken);
            await File.WriteAllTextAsync(path: prefix + ".stderr", contents: response.Stderr, cancellationToken);
            await File.WriteAllTextAsync(
                path: prefix + ".status",
                contents: response.Status.ToString(CultureInfo.InvariantCulture),
                cancellationToken: cancellationToken
            );
        }
    }

    private static async Task<IReadOnlyList<string>> CallsAsync(string directory, CancellationToken cancellationToken)
    {
        string calls = Path.Combine(path1: directory, path2: "calls");

        if (!File.Exists(calls))
        {
            return [];
        }

        string text = await File.ReadAllTextAsync(path: calls, encoding: Encoding.UTF8, cancellationToken);

        return [.. text.Split('\n').SkipLast(1)];
    }

    private static async Task<PodmanResult> AskAsync(
        PodmanQueries queries,
        string function,
        string argument,
        CancellationToken cancellationToken
    )
    {
        return function switch
        {
            "current_agent_image_sha" => await queries.ImageShaAsync(
                image: argument,
                cancellationToken: cancellationToken
            ),
            "agent_container_exists" => await queries.ContainerExistsAsync(
                name: argument,
                cancellationToken: cancellationToken
            ),
            "agent_container_running" => await queries.ContainerRunningAsync(
                name: argument,
                cancellationToken: cancellationToken
            ),
            "agent_image_cached" => await queries.ImageExistsAsync(
                image: argument,
                cancellationToken: cancellationToken
            ),
            _ => throw new InvalidOperationException("No query for " + function),
        };
    }
}
