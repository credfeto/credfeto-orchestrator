using System;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Commands;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using Credfeto.Orchestrator.Podman;

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

        if (GitCommandParser.IsVerb(args) || PodmanCommandParser.IsVerb(args))
        {
            Task<int> git = RunProcessVerbAsync(args: args, cancellationToken: shutdown.Token);

            if (await Task.WhenAny(git, signalled.Task) != git)
            {
                await shutdown.CancelAsync();
            }

            return await git;
        }

        await using Stream input = Console.OpenStandardInput();
        using HttpClient httpClient = new();
        CommandRunner runner = new(
            fingerprints: new FingerprintCalculator(),
            files: new FileContentReader(),
            github: new GitHubReader(
                new McpToolCaller(httpClient: httpClient, settings: static () =>
                    CfwfMcpSettingsLoader.Load(Environment.GetEnvironmentVariable)
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

    // git and podman have their own runners: they write the bytes git or podman printed to stdout untouched, not
    // through Console.Out
    private static async Task<int> RunProcessVerbAsync(string[] args, CancellationToken cancellationToken)
    {
        await using Stream output = Console.OpenStandardOutput();

        if (PodmanCommandParser.IsVerb(args))
        {
            return await PodmanCommandRunner
                .CreateDefault()
                .RunAsync(args: args, output: output, error: Console.Error, cancellationToken: cancellationToken);
        }

        return await GitCommandRunner
            .CreateDefault()
            .RunAsync(args: args, output: output, error: Console.Error, cancellationToken: cancellationToken);
    }
}
