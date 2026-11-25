using System;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Commands;
using Credfeto.Orchestrator.Discovery;
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

        if (GitCommandParser.IsVerb(args))
        {
            Task<int> git = RunGitAsync(args: args, cancellationToken: shutdown.Token);

            if (await Task.WhenAny(git, signalled.Task) != git)
            {
                await shutdown.CancelAsync();
            }

            return await git;
        }

        await using Stream input = Console.OpenStandardInput();
        using HttpClient httpClient = new();
        CommandRunner runner = CreateRunner(httpClient);

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

    private static CommandRunner CreateRunner(HttpClient httpClient)
    {
        GitHubReader github = new(
            new McpToolCaller(httpClient: httpClient, settings: static () =>
                CfwfMcpSettingsLoader.Load(Environment.GetEnvironmentVariable)
            )
        );
        UrlReader urls = new();
        RetryDelay delay = new();

        return new(
            fingerprints: new FingerprintCalculator(),
            files: new FileContentReader(),
            github: github,
            discovery: new(
                priorities: new PriorityFeed(urls: urls, delay: delay),
                trustedLogins: new TrustedLoginsReader(github: github, delay: delay),
                health: new GitHubIncidentGate(urls)
            )
        );
    }

    private static void Signal(PosixSignalContext context, TaskCompletionSource signalled)
    {
        context.Cancel = true;
        signalled.TrySetResult();
    }

    // git has its own runner: it writes the bytes git printed to stdout untouched, not through Console.Out
    private static async Task<int> RunGitAsync(string[] args, CancellationToken cancellationToken)
    {
        await using Stream output = Console.OpenStandardOutput();

        return await GitCommandRunner
            .CreateDefault()
            .RunAsync(args: args, output: output, error: Console.Error, cancellationToken: cancellationToken);
    }
}
