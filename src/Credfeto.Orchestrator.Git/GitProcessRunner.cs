using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Git;

// Runs the git command line, as lib/git does: git finds the same config, ssh and credential helpers, and its
// stderr goes straight to this process's stderr, so a caller sees exactly what bash's git would have written there
public sealed class GitProcessRunner : IGitRunner
{
    private const string GIT = "git";

    private readonly bool _discardErrors;
    private readonly IReadOnlyDictionary<string, string?> _environment;
    private readonly string _executable;
    private readonly string? _workingDirectory;

    public GitProcessRunner()
        : this(
            executable: GIT,
            workingDirectory: null,
            environment: new Dictionary<string, string?>(StringComparer.Ordinal),
            discardErrors: false
        ) { }

    // The tests' constructor: environment entries are set, or removed when null, on top of this process's
    // environment, and discardErrors throws git's stderr away instead of passing it through
    public GitProcessRunner(
        string executable,
        string? workingDirectory,
        IReadOnlyDictionary<string, string?> environment,
        bool discardErrors
    )
    {
        this._discardErrors = discardErrors;
        this._executable = executable;
        this._workingDirectory = workingDirectory;
        this._environment = environment;
    }

    public async ValueTask<GitResult> RunAsync(
        string repository,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken
    )
    {
        cancellationToken.ThrowIfCancellationRequested();

        using Process process = new();
        process.StartInfo = this.StartInfo(repository: repository, arguments: arguments);
        Start(process);

        try
        {
            using MemoryStream output = new();
            Task errors = this._discardErrors
                ? process.StandardError.BaseStream.CopyToAsync(
                    destination: Stream.Null,
                    cancellationToken: cancellationToken
                )
                : Task.CompletedTask;
            await process.StandardOutput.BaseStream.CopyToAsync(
                destination: output,
                cancellationToken: cancellationToken
            );
            await errors;
            await process.WaitForExitAsync(cancellationToken);

            return new(ExitCode: process.ExitCode, Output: output.ToArray());
        }
        catch (OperationCanceledException)
        {
            Kill(process);

            throw;
        }
    }

    private ProcessStartInfo StartInfo(string repository, IReadOnlyList<string> arguments)
    {
        ProcessStartInfo info = new(this._executable)
        {
            UseShellExecute = false,
            RedirectStandardInput = false,
            RedirectStandardOutput = true,
            RedirectStandardError = this._discardErrors,
        };

        if (this._workingDirectory is not null)
        {
            info.WorkingDirectory = this._workingDirectory;
        }

        info.ArgumentList.Add("-C");
        info.ArgumentList.Add(repository);

        foreach (string argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        foreach ((string name, string? value) in this._environment)
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

        return info;
    }

    private static void Start(Process process)
    {
        try
        {
            process.Start();
        }
        catch (Win32Exception exception)
        {
            throw new GitException(
                message: $"{process.StartInfo.FileName} could not be started: {exception.Message}",
                innerException: exception
            );
        }
    }

    private static void Kill(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
            // It has already exited
        }
    }
}
