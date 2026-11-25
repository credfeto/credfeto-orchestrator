using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Credfeto.Orchestrator.Git.Tests;

// Builds the fixture's scenarios once for the parity tests, each in a directory of its name under a throwaway root,
// by running the scenario scripts with bash in the fixture's environment, as test/oneshot-git-parity.bats does
public sealed class GitParityRepositories : IAsyncLifetime
{
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "git-parity-" + Guid.NewGuid().ToString("N"));

    public IReadOnlyDictionary<string, string?> Environment { get; private set; } =
        new Dictionary<string, string?>(StringComparer.Ordinal);

    public async ValueTask InitializeAsync()
    {
        this.Environment = await GitParityFixture.EnvironmentAsync(CancellationToken.None);

        foreach (
            KeyValuePair<string, string> scenario in await GitParityFixture.ScenarioScriptsAsync(CancellationToken.None)
        )
        {
            string directory = Path.Combine(path1: this.Root, path2: scenario.Key);
            Directory.CreateDirectory(directory);
            await this.BuildAsync(directory: directory, script: scenario.Value);
        }
    }

    public ValueTask DisposeAsync()
    {
        if (Directory.Exists(this.Root))
        {
            Directory.Delete(path: this.Root, recursive: true);
        }

        return ValueTask.CompletedTask;
    }

    private async ValueTask BuildAsync(string directory, string script)
    {
        ProcessStartInfo info = new("bash")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = directory,
        };
        info.ArgumentList.Add("-e");
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add(script);

        foreach ((string name, string? value) in this.Environment)
        {
            if (value is null)
            {
                info.Environment.Remove(name);
            }
            else
            {
                info.Environment[name] = value;
            }
        }

        using Process process = Process.Start(info) ?? throw new InvalidOperationException("bash did not start");
        Task<string> output = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        Task<string> error = process.StandardError.ReadToEndAsync(CancellationToken.None);
        await process.WaitForExitAsync(CancellationToken.None);
        await output;
        string problems = await error;

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"The scenario in {directory} failed ({process.ExitCode}): {problems}");
        }
    }
}
