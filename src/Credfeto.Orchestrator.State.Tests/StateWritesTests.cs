using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

// The writes the parity fixture cannot hold: a FIFO in the file's place (bash would block on it), a cancelled or
// failing write part-way, a long text, and what the runner says
[SupportedOSPlatform("linux")]
[Collection(UmaskSerial.Name)]
public sealed class StateWritesTests : TestBase, IDisposable
{
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("state-writes-");

    public void Dispose()
    {
        StateWritesTree.Remove(this._root);
    }

    [Fact]
    public async Task AFifoInTheFilesPlaceIsRefusedAsync()
    {
        string file = this.Session("PullRequest_7.infra-failures");
        NativeMethods.Fifo(file);

        (int status, string error) = await RunAsync(
            args: this.InfraFailures("3"),
            input: [],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: StateCommandRunner.Refused, actual: status);
        Assert.Contains(
            expectedSubstring: "single link",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Equal(expected: ["PullRequest_7.infra-failures"], actual: this.Names());
    }

    [Fact]
    public async Task ACancelledWriteLeavesTheFileAsItWasAsync()
    {
        string file = this.Session("Issue_9.invocations");
        await File.WriteAllTextAsync(path: file, contents: "1 2\n", cancellationToken: this.CancellationToken());

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
            await StateFileWriter.ReplaceAsync(
                path: file,
                content: "3 4\n"u8.ToArray(),
                replacement: StateReplacement.IN_PLACE,
                cancellationToken: new CancellationToken(canceled: true)
            )
        );

        Assert.Equal(
            expected: "1 2\n",
            actual: await File.ReadAllTextAsync(path: file, cancellationToken: this.CancellationToken())
        );
        Assert.Equal(expected: ["Issue_9.invocations"], actual: this.Names());
    }

    [Fact]
    public async Task AFailingInputLeavesTheFileAsItWasAsync()
    {
        string file = this.Session("Issue_9.last-diagnostic");
        await File.WriteAllTextAsync(path: file, contents: "old", cancellationToken: this.CancellationToken());

        (int status, string error) = await RunAsync(
            args: this.LastDiagnostic(),
            input: null,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: StateCommandRunner.Failed, actual: status);
        Assert.Contains(
            expectedSubstring: "broken pipe",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Equal(
            expected: "old",
            actual: await File.ReadAllTextAsync(path: file, cancellationToken: this.CancellationToken())
        );
    }

    [Fact]
    public async Task ALongTextIsWrittenByteForByteAsync()
    {
        byte[] text = [.. Enumerable.Range(start: 0, count: 1 << 20).Select(value => (byte)(value % 251 + 1))];

        (int status, string error) = await RunAsync(
            args: this.LastDiagnostic(),
            input: [.. text, (byte)'\n'],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: StateQueries.Answered, actual: status);
        Assert.Equal(expected: string.Empty, actual: error);
        Assert.Equal(
            expected: text,
            actual: await File.ReadAllBytesAsync(
                path: this.Session("Issue_9.last-diagnostic"),
                cancellationToken: this.CancellationToken()
            )
        );
        Assert.Equal(expected: ["Issue_9.last-diagnostic"], actual: this.Names());
    }

    [Theory]
    [InlineData("")]
    [InlineData("no newline")]
    public async Task ATextWithoutTheHereStringsNewlineIsRefusedAsync(string text)
    {
        (int status, string error) = await RunAsync(
            args: this.LastDiagnostic(),
            input: System.Text.Encoding.UTF8.GetBytes(text),
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: StateCommandRunner.Refused, actual: status);
        Assert.Contains(
            expectedSubstring: "here-string",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Empty(this.Names());
    }

    [Fact]
    public async Task AWritePrintsNothingAsync()
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using MemoryStream output = new();

        int status = await StateCommandRunner
            .CreateDefault()
            .RunAsync(
                args: this.InfraFailures("3"),
                output: output,
                error: error,
                cancellationToken: this.CancellationToken()
            );

        Assert.Equal(expected: StateQueries.Answered, actual: status);
        Assert.Equal(expected: 0, actual: output.Length);
        Assert.Equal(
            expected: "3\n",
            actual: await File.ReadAllTextAsync(
                path: this.Session("PullRequest_7.infra-failures"),
                cancellationToken: this.CancellationToken()
            )
        );
    }

    private string Session(string name)
    {
        return this._root.FullName + "/" + name;
    }

    private string[] Names()
    {
        return [.. this._root.EnumerateFileSystemInfos().Select(entry => entry.Name).Order(StringComparer.Ordinal)];
    }

    private string[] InfraFailures(string count)
    {
        return
        [
            "state",
            "save-infra-failures",
            "--session-dir",
            this._root.FullName,
            "--type",
            "PullRequest",
            "--id",
            "7",
            "--count",
            count,
        ];
    }

    private string[] LastDiagnostic()
    {
        return ["state", "save-last-diagnostic", "--session-dir", this._root.FullName, "--type", "Issue", "--id", "9"];
    }

    // input null: a stdin whose every read fails
    private static async Task<(int Status, string Error)> RunAsync(
        string[] args,
        byte[]? input,
        CancellationToken cancellationToken
    )
    {
        await using StringWriter error = new(CultureInfo.InvariantCulture);
        await using MemoryStream output = new();
        StateCommandRunner runner = new(queries: new StateQueries(TimeProvider.System), input: () =>
            input is null ? new FailingReadStream() : new MemoryStream(input)
        );

        int status = await runner.RunAsync(
            args: args,
            output: output,
            error: error,
            cancellationToken: cancellationToken
        );

        return (status, error.ToString());
    }
}
