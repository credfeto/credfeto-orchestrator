using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// Runs a script standing in for podman, in a throwaway directory next to the tests (a temporary directory may not let
// a script run)
[SupportedOSPlatform("linux")]
public sealed class PodmanProcessRunnerTests : TestBase, IDisposable
{
    private const string SCRIPT = """
        #!/usr/bin/env bash
        printf '[%s]\n' "$@"
        printf 'in %s\n' "$(basename "$(pwd)")"
        printf 'value %s\n' "${PODMAN_RUNNER_VALUE-unset}"
        printf 'removed %s\n' "${PODMAN_RUNNER_REMOVED-unset}"
        printf 'stand-in stderr\n' >&2
        exit "${PODMAN_RUNNER_STATUS:-0}"
        """;

    private readonly string _directory = Path.Combine(
        path1: AppContext.BaseDirectory,
        path2: "podman-runner-" + Guid.NewGuid().ToString("N")
    );

    public PodmanProcessRunnerTests()
    {
        Directory.CreateDirectory(this._directory);
    }

    public void Dispose()
    {
        Directory.Delete(path: this._directory, recursive: true);
    }

    [Fact]
    public async Task StdoutAndTheExitStatusComeBackWithEachArgumentWholeAsync()
    {
        PodmanProcessRunner podman = await this.RunnerAsync(
            new Dictionary<string, string?>(StringComparer.Ordinal) { ["PODMAN_RUNNER_STATUS"] = "3" }
        );

        PodmanResult result = await podman.RunAsync(
            arguments: ["inspect", "a name", ""],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 3, actual: result.ExitCode);
        Assert.Equal(
            expected: "[inspect]\n[a name]\n[]\nin "
                + Path.GetFileName(this._directory)
                + "\nvalue unset\nremoved unset\n",
            actual: Encoding.UTF8.GetString(result.Output.Span)
        );
    }

    [Fact]
    public async Task TheEnvironmentIsSetAndRemovedOnTopOfThisProcessesAsync()
    {
        Environment.SetEnvironmentVariable(variable: "PODMAN_RUNNER_REMOVED", value: "inherited");

        try
        {
            PodmanProcessRunner podman = await this.RunnerAsync(
                new Dictionary<string, string?>(StringComparer.Ordinal)
                {
                    ["PODMAN_RUNNER_VALUE"] = "from the environment",
                    ["PODMAN_RUNNER_REMOVED"] = null,
                }
            );

            PodmanResult result = await podman.RunAsync(arguments: [], cancellationToken: this.CancellationToken());

            Assert.Equal(expected: 0, actual: result.ExitCode);
            Assert.EndsWith(
                expectedEndString: "value from the environment\nremoved unset\n",
                actualString: Encoding.UTF8.GetString(result.Output.Span),
                comparisonType: StringComparison.Ordinal
            );
        }
        finally
        {
            Environment.SetEnvironmentVariable(variable: "PODMAN_RUNNER_REMOVED", value: null);
        }
    }

    [Fact]
    public Task APodmanThatCannotBeStartedFailsAsync()
    {
        PodmanProcessRunner podman = new(
            executable: Path.Combine(path1: this._directory, path2: "no-such-podman"),
            workingDirectory: this._directory,
            environment: new Dictionary<string, string?>(StringComparer.Ordinal),
            discardErrors: true
        );

        return Assert.ThrowsAsync<PodmanException>(() =>
            podman.RunAsync(arguments: ["version"], cancellationToken: this.CancellationToken()).AsTask()
        );
    }

    [Fact]
    public async Task ACancelledRunStopsAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();
        PodmanProcessRunner podman = await this.RunnerAsync(new Dictionary<string, string?>(StringComparer.Ordinal));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            podman.RunAsync(arguments: ["version"], cancellationToken: cancelled.Token).AsTask()
        );
    }

    private async Task<PodmanProcessRunner> RunnerAsync(IReadOnlyDictionary<string, string?> environment)
    {
        string script = Path.Combine(path1: this._directory, path2: "podman");
        await File.WriteAllTextAsync(
            path: script,
            contents: SCRIPT + "\n",
            cancellationToken: this.CancellationToken()
        );
        File.SetUnixFileMode(
            path: script,
            mode: UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
        );

        return new(
            executable: script,
            workingDirectory: this._directory,
            environment: environment,
            discardErrors: true
        );
    }
}
