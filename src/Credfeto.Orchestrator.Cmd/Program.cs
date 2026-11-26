using System;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Agents;
using Credfeto.Orchestrator.Commands;
using Credfeto.Orchestrator.Discord;
using Credfeto.Orchestrator.Discovery;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using Credfeto.Orchestrator.Install;
using Credfeto.Orchestrator.Podman;
using Credfeto.Orchestrator.State;

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

        // UTF-8 whatever the locale, as jq and gh print: a prompt goes back to bash byte for byte
        Console.OutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

        using CancellationTokenSource shutdown = new();

        Task<int> run = RunAsync(args: args, cancellationToken: shutdown.Token);

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

    private static Task<int> RunAsync(string[] args, CancellationToken cancellationToken)
    {
        // --version and --self-test answer from the tool itself: oneshot's self-install asks them before using a binary
        if (SelfCommandParser.IsVerb(args))
        {
            return SelfCommandRunner
                .CreateDefault(ToolVersion.Of(typeof(Program).Assembly))
                .RunAsync(args: args, output: Console.Out, error: Console.Error, cancellationToken: cancellationToken)
                .AsTask();
        }

        // discord only prints the payload or text it builds from its arguments and, for the text commands, stdin
        if (DiscordCommandParser.IsVerb(args))
        {
            return DiscordCommandRunner
                .RunAsync(
                    args: args,
                    input: Console.OpenStandardInput,
                    output: Console.Out,
                    error: Console.Error,
                    cancellationToken: cancellationToken
                )
                .AsTask();
        }

        if (GitCommandParser.IsVerb(args))
        {
            return RunGitAsync(args: args, cancellationToken: cancellationToken);
        }

        // agent asks the ssh-agent at a socket for its keys, or stops the run's ssh-agent: it prints nothing
        if (AgentCommandParser.IsVerb(args))
        {
            return AgentCommandRunner
                .CreateDefault()
                .RunAsync(args: args, error: Console.Error, cancellationToken: cancellationToken)
                .AsTask();
        }

        if (PromptCommandParser.IsVerb(args))
        {
            return RunPromptAsync(args: args, cancellationToken: cancellationToken);
        }

        if (PodmanCommandParser.IsVerb(args))
        {
            return RunPodmanAsync(args: args, cancellationToken: cancellationToken);
        }

        if (StateCommandParser.IsVerb(args))
        {
            return RunStateAsync(args: args, cancellationToken: cancellationToken);
        }

        return RunCommandAsync(args: args, cancellationToken: cancellationToken);
    }

    // git has its own runner: it writes the bytes git printed to stdout untouched, not through Console.Out
    private static async Task<int> RunGitAsync(string[] args, CancellationToken cancellationToken)
    {
        await using Stream output = Console.OpenStandardOutput();

        return await GitCommandRunner
            .CreateDefault()
            .RunAsync(args: args, output: output, error: Console.Error, cancellationToken: cancellationToken);
    }

    // podman has its own runner: it writes the bytes podman printed to stdout untouched, not through Console.Out
    private static async Task<int> RunPodmanAsync(string[] args, CancellationToken cancellationToken)
    {
        await using Stream output = Console.OpenStandardOutput();

        return await PodmanCommandRunner
            .CreateDefault()
            .RunAsync(args: args, output: output, error: Console.Error, cancellationToken: cancellationToken);
    }

    // prompt has its own runner: it reads none of the files or GitHub data the other commands read
    private static async Task<int> RunPromptAsync(string[] args, CancellationToken cancellationToken)
    {
        await using Stream input = Console.OpenStandardInput();

        return await new PromptCommandRunner(Environment.GetEnvironmentVariable).RunAsync(
            args: args,
            input: input,
            output: Console.Out,
            error: Console.Error,
            cancellationToken: cancellationToken
        );
    }

    // state has its own runner: it writes the bytes a state file holds to stdout untouched, not through Console.Out
    private static async Task<int> RunStateAsync(string[] args, CancellationToken cancellationToken)
    {
        await using Stream output = Console.OpenStandardOutput();

        return await StateCommandRunner
            .CreateDefault()
            .RunAsync(args: args, output: output, error: Console.Error, cancellationToken: cancellationToken);
    }

    private static async Task<int> RunCommandAsync(string[] args, CancellationToken cancellationToken)
    {
        await using Stream input = Console.OpenStandardInput();
        using HttpClient httpClient = new();
        CommandRunner runner = CreateRunner(httpClient);

        return await runner.RunAsync(
            args: args,
            input: input,
            output: Console.Out,
            error: Console.Error,
            cancellationToken: cancellationToken
        );
    }
}
