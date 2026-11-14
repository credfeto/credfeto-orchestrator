using System;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Commands;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Cmd;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        // SIGTERM and Ctrl+C cancel the running command, which then exits with ExitCodes.Cancelled
        TaskCompletionSource signalled = new(TaskCreationOptions.RunContinuationsAsynchronously);
        using PosixSignalRegistration terminate = PosixSignalRegistration.Create(
            signal: PosixSignal.SIGTERM,
            handler: context => Signal(context: context, signalled: signalled)
        );
        using PosixSignalRegistration interrupt = PosixSignalRegistration.Create(
            signal: PosixSignal.SIGINT,
            handler: context => Signal(context: context, signalled: signalled)
        );

        using CancellationTokenSource shutdown = new();
        await using Stream input = Console.OpenStandardInput();
        using HttpClient httpClient = new();
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FileContentReader(),
            github: new GitHubReader(
                new McpToolCaller(
                    httpClient: httpClient,
                    settings: static () => CfwfMcpSettingsLoader.Load(Environment.GetEnvironmentVariable)
                )
            )
        );

        Task<int> run = runner
            .RunAsync(
                args: args,
                input: input,
                output: Console.Out,
                error: Console.Error,
                cancellationToken: shutdown.Token
            )
            .AsTask();

        if (await Task.WhenAny(run, signalled.Task) != run)
        {
            await shutdown.CancelAsync();
        }

        return await run;
    }

    private static void Signal(PosixSignalContext context, TaskCompletionSource signalled)
    {
        context.Cancel = true;
        signalled.TrySetResult();
    }
}
