using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;

namespace Credfeto.Orchestrator.Install;

// credfeto-orchestrator --version | --self-test: what oneshot's self-install (lib/self-install) asks of a binary it
// has just unpacked, before it points the current link at it
public sealed class SelfCommandRunner
{
    public const int Failed = 1;

    public const int Usage = 2;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator --version
               credfeto-orchestrator --self-test

        --version prints the tool's informational version (the package version, with any +build metadata).

        --self-test runs fast offline checks of the tool's own parts against tiny built-in inputs (config resolution,
        JSON parsing and printing, a pull request fingerprint and the embedded prompt templates), printing one line a
        check. It reads no files and makes no network calls.

        Exit codes: 0 success; 1 a self-test check failed (named on stderr); 2 a usage error.
        """;

    private readonly IReadOnlyList<ISelfTestCheck> _checks;

    private readonly string _version;

    public SelfCommandRunner(string version, IReadOnlyList<ISelfTestCheck> checks)
    {
        this._version = version;
        this._checks = checks;
    }

    public static SelfCommandRunner CreateDefault(string version)
    {
        return new(
            version: version,
            checks:
            [
                new ConfigSelfTest(),
                new JsonSelfTest(),
                new FingerprintSelfTest(new FingerprintCalculator()),
                new PromptTemplatesSelfTest(),
            ]
        );
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        SelfQuery? query = SelfCommandParser.Parse(args: args, error: out string problem);

        if (query is null)
        {
            await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
            await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return Usage;
        }

        if (query == SelfQuery.VERSION)
        {
            await output.WriteLineAsync(this._version.AsMemory(), cancellationToken);

            return 0;
        }

        try
        {
            return await this.SelfTestAsync(output: output, error: error, cancellationToken: cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return Cancelled;
        }
    }

    private async ValueTask<int> SelfTestAsync(TextWriter output, TextWriter error, CancellationToken cancellationToken)
    {
        foreach (ISelfTestCheck check in this._checks)
        {
            try
            {
                await check.RunAsync(cancellationToken);
            }
            catch (SelfTestFailedException exception)
            {
                await error.WriteLineAsync(
                    $"{PROGRAM}: self-test: {check.Name} failed: {exception.Message}".AsMemory(),
                    cancellationToken
                );

                return Failed;
            }

            await output.WriteLineAsync($"self-test: {check.Name} ok".AsMemory(), cancellationToken);
        }

        await output.WriteLineAsync($"self-test: passed ({this._checks.Count} checks)".AsMemory(), cancellationToken);

        return 0;
    }
}
