using System;
using System.Globalization;
using System.IO;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

[SupportedOSPlatform("linux")]
public sealed class StateQueriesTests : TestBase, IDisposable
{
    private static readonly DateTimeOffset Now = new(
        year: 2026,
        month: 11,
        day: 25,
        hour: 12,
        minute: 0,
        second: 0,
        offset: TimeSpan.Zero
    );

    private readonly DirectoryInfo _root;
    private readonly FakeTimeProvider _timeProvider;

    public StateQueriesTests()
    {
        this._root = Directory.CreateTempSubdirectory("state-queries-");
        this._timeProvider = new(Now);
        Directory.CreateDirectory(this.Session);
    }

    private string State => this._root.FullName + "/state";

    private string Session => this.State + "/owner/repo";

    public void Dispose()
    {
        this._root.Delete(recursive: true);
    }

    [Theory]
    [InlineData(-1, StateQueries.Stale)]
    [InlineData(0, StateQueries.Stale)]
    [InlineData(1, StateQueries.Answered)]
    public async Task TheRateLimitHoldsUntilTheResetSecondAsync(int secondsAhead, int expected)
    {
        long reset = Now.ToUnixTimeSeconds() + secondsAhead;
        await this.WriteAsync(path: "owner/rate-limit", content: reset.ToString(CultureInfo.InvariantCulture) + "\n");

        StateResult result = await new StateQueries(this._timeProvider).RateLimitAsync(
            stateDirectory: this.State,
            owner: "owner",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: expected, actual: result.ExitCode);
        Assert.True(condition: result.Output.IsEmpty, userMessage: "rate-limit prints nothing");
    }

    [Fact]
    public async Task AFileThatCannotBeReadIsLeftToBashAsync()
    {
        string path = await this.WriteAsync(path: "owner/repo/PullRequest_7.infra-failures", content: "3\n");
        File.SetUnixFileMode(path: path, mode: UnixFileMode.None);

        if (await CanReadAsync(path))
        {
            // Running as root: every file can be read
            return;
        }

        await Assert.ThrowsAsync<StateRefusedException>(async () =>
            await StateQueries.InfraFailuresAsync(
                sessionDirectory: this.Session,
                itemType: "PullRequest",
                itemId: "7",
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task AMarkerThatCannotBeReadIsStillThereAsync()
    {
        string path = await this.WriteAsync(path: "owner/repo/Issue_5.plan-block", content: string.Empty);
        File.SetUnixFileMode(path: path, mode: UnixFileMode.None);

        StateResult result = StateQueries.Marker(
            sessionDirectory: this.Session,
            itemType: "Issue",
            itemId: "5",
            kind: "plan-block"
        );

        Assert.Equal(expected: StateQueries.Answered, actual: result.ExitCode);
    }

    [Theory]
    [InlineData("3 1\n", "PullRequest", "3 1")]
    [InlineData("3\n", "PullRequest", "0 0")]
    [InlineData("3\n", "Issue", "3 0")]
    [InlineData("3 x\n", "Issue", "3 0")]
    [InlineData("4 2\n5\n", "Issue", "4 0")]
    [InlineData("4 2\n5\n", "PullRequest", "0 0")]
    public async Task InvocationsReadAsTheShellFunctionsDoAsync(string content, string itemType, string expected)
    {
        await this.WriteAsync(path: "owner/repo/" + itemType + "_7.invocations", content: content);

        StateResult result = await StateQueries.InvocationsAsync(
            sessionDirectory: this.Session,
            itemType: itemType,
            itemId: "7",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: expected, actual: Encoding.ASCII.GetString(result.Output.Span));
    }

    [Theory]
    [InlineData("10\n30\n20\n", "3", "20\n", StateQueries.Answered)]
    [InlineData("10\n30\n", "3", "", StateQueries.NotFound)]
    [InlineData("7\n07\n007\n", "3", "07\n", StateQueries.Answered)]
    [InlineData("99999999999999999999999\n1\n2\n", "1", "2\n", StateQueries.Answered)]
    public async Task TheBaselineIsTheMedianAsync(string content, string minSamples, string expected, int status)
    {
        await this.WriteAsync(path: "owner/pull-durations", content: content);

        StateResult result = await StateQueries.PullDurationBaselineAsync(
            stateDirectory: this.State,
            owner: "owner",
            minSamples: minSamples,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: status, actual: result.ExitCode);
        Assert.Equal(expected: expected, actual: Encoding.ASCII.GetString(result.Output.Span));
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("")]
    [InlineData("-1")]
    [InlineData("1234567890123456789")]
    public async Task AMinimumBashMayReadDifferentlyIsRefusedAsync(string minSamples)
    {
        await this.WriteAsync(path: "owner/pull-durations", content: "1\n");

        await Assert.ThrowsAsync<StateRefusedException>(async () =>
            await StateQueries.PullDurationBaselineAsync(
                stateDirectory: this.State,
                owner: "owner",
                minSamples: minSamples,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task ALastDiagnosticIsPrintedByteForByteAsync()
    {
        byte[] content = [0xff, (byte)'\n', (byte)'\n'];
        await File.WriteAllBytesAsync(
            path: this.Session + "/PullRequest_7.last-diagnostic",
            bytes: content,
            cancellationToken: this.CancellationToken()
        );

        StateResult result = await StateQueries.LastDiagnosticAsync(
            sessionDirectory: this.Session,
            itemType: "PullRequest",
            itemId: "7",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: content, actual: result.Output.ToArray());
    }

    private static async ValueTask<bool> CanReadAsync(string path)
    {
        try
        {
            await using FileStream stream = File.OpenRead(path);

            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task<string> WriteAsync(string path, string content)
    {
        string full = this.State + "/" + path;
        Directory.CreateDirectory(Path.GetDirectoryName(full) ?? this.State);
        await File.WriteAllTextAsync(path: full, contents: content, cancellationToken: this.CancellationToken());

        return full;
    }
}
