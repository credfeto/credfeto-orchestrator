using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman;

// Runs the podman command line, as lib/podman does: podman finds the same configuration, storage and socket, and its
// stderr goes straight to this process's stderr, so a caller sees exactly what bash's podman would have written there
public sealed class PodmanProcessRunner : IPodmanRunner
{
    private const string PODMAN = "podman";

    private readonly bool _discardErrors;
    private readonly IReadOnlyDictionary<string, string?> _environment;
    private readonly string _executable;
    private readonly string? _workingDirectory;

    public PodmanProcessRunner()
        : this(
            executable: PODMAN,
            workingDirectory: null,
            environment: new Dictionary<string, string?>(StringComparer.Ordinal),
            discardErrors: false
        ) { }

    // The tests' constructor: environment entries are set, or removed when null, on top of this process's
    // environment, and discardErrors throws podman's stderr away instead of passing it through
    public PodmanProcessRunner(
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

    public async ValueTask<PodmanResult> RunAsync(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        using Process process = new();
        process.StartInfo = this.StartInfo(arguments);
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

    private ProcessStartInfo StartInfo(IReadOnlyList<string> arguments)
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
            throw new PodmanException(
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
