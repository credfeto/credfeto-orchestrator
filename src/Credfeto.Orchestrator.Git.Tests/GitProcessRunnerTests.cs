using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Git.Tests;

// Runs the real git command line in a throwaway directory
public sealed class GitProcessRunnerTests : TestBase, IDisposable
{
    private static readonly IReadOnlyDictionary<string, string?> Isolated = new Dictionary<string, string?>(
        StringComparer.Ordinal
    )
    {
        ["GIT_CONFIG_NOSYSTEM"] = "1",
        ["GIT_CONFIG_GLOBAL"] = "/dev/null",
        ["GIT_DIR"] = null,
        ["GIT_INDEX_FILE"] = null,
        ["GIT_WORK_TREE"] = null,
    };

    private readonly string _directory = Path.Combine(Path.GetTempPath(), "git-runner-" + Guid.NewGuid().ToString("N"));

    public GitProcessRunnerTests()
    {
        Directory.CreateDirectory(this._directory);
    }

    public void Dispose()
    {
        Directory.Delete(path: this._directory, recursive: true);
    }

    [Fact]
    public async Task StdoutAndTheExitStatusComeBackFromGitAsync()
    {
        GitProcessRunner git = this.Runner(Isolated);
        await this.RunAsync(git: git, arguments: ["init", "-q", "-b", "main", "repo"]);

        GitResult branch = await git.RunAsync(
            repository: Path.Combine(path1: this._directory, path2: "repo"),
            arguments: ["branch", "--show-current"],
            cancellationToken: this.CancellationToken()
        );
        GitResult head = await git.RunAsync(
            repository: Path.Combine(path1: this._directory, path2: "repo"),
            arguments: ["rev-parse", "--verify", "-q", "HEAD"],
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 0, actual: branch.ExitCode);
        Assert.Equal(expected: "main\n", actual: Encoding.UTF8.GetString(branch.Output.Span));
        Assert.Equal(expected: 1, actual: head.ExitCode);
        Assert.Equal(expected: 0, actual: head.Output.Length);
    }

    [Fact]
    public async Task AnEmptyRepositoryIsTheWorkingDirectoryAsync()
    {
        GitResult result = await this.RunAsync(git: this.Runner(Isolated), arguments: ["rev-parse", "--git-dir"]);

        Assert.Equal(expected: 128, actual: result.ExitCode);
    }

    [Fact]
    public async Task TheEnvironmentIsSetOnTopOfThisProcessesAsync()
    {
        Dictionary<string, string?> environment = new(Isolated, StringComparer.Ordinal)
        {
            ["GIT_CONFIG_COUNT"] = "1",
            ["GIT_CONFIG_KEY_0"] = "parity.value",
            ["GIT_CONFIG_VALUE_0"] = "from the environment",
        };

        GitResult result = await this.RunAsync(
            git: this.Runner(environment),
            arguments: ["config", "--get", "parity.value"]
        );

        Assert.Equal(expected: 0, actual: result.ExitCode);
        Assert.Equal(expected: "from the environment\n", actual: Encoding.UTF8.GetString(result.Output.Span));
    }

    [Fact]
    public Task AGitThatCannotBeStartedFailsAsync()
    {
        GitProcessRunner git = new(
            executable: Path.Combine(path1: this._directory, path2: "no-such-git"),
            workingDirectory: this._directory,
            environment: Isolated,
            discardErrors: true
        );

        return Assert.ThrowsAsync<GitException>(() => this.RunAsync(git: git, arguments: ["status"]));
    }

    [Fact]
    public async Task ACancelledRunStopsAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            this.Runner(Isolated)
                .RunAsync(repository: "", arguments: ["status"], cancellationToken: cancelled.Token)
                .AsTask()
        );
    }

    private GitProcessRunner Runner(IReadOnlyDictionary<string, string?> environment)
    {
        return new(executable: "git", workingDirectory: this._directory, environment: environment, discardErrors: true);
    }

    private async Task<GitResult> RunAsync(GitProcessRunner git, IReadOnlyList<string> arguments)
    {
        return await git.RunAsync(repository: "", arguments: arguments, cancellationToken: this.CancellationToken());
    }
}
