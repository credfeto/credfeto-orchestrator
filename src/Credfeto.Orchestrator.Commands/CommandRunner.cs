using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;

namespace Credfeto.Orchestrator.Commands;

public sealed class CommandRunner
{
    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator fingerprint pr [--trusted-file <file>] [--review-comments-file <file>] [--schema-version <n>]
               credfeto-orchestrator fingerprint issue [--trusted-file <file>] [--plan-approved <value>] [--schema-version <n>]

        Reads the pull request or issue JSON on stdin and prints its fingerprint, exactly as
        fingerprint_pr_json / fingerprint_issue_json in lib/fingerprints do.

        Exit codes: 0 printed; 1 the fingerprint could not be computed; 2 a usage error.
        """;

    private static readonly Encoding Utf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    private readonly IFileContentReader _files;
    private readonly IFingerprintCalculator _fingerprints;

    public CommandRunner(IFingerprintCalculator fingerprints, IFileContentReader files)
    {
        this._fingerprints = fingerprints;
        this._files = files;
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Stream input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        if (args.Count == 1 && IsHelp(args[0]))
        {
            await output.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return ExitCodes.Success;
        }

        FingerprintCommand? command = FingerprintCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
            await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return ExitCodes.Usage;
        }

        try
        {
            string fingerprint = await this.FingerprintAsync(
                command: command,
                input: input,
                cancellationToken: cancellationToken
            );
            await output.WriteAsync(fingerprint.AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            return ExitCodes.Success;
        }
        catch (FingerprintException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (IOException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (UnauthorizedAccessException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    private async ValueTask<string> FingerprintAsync(
        FingerprintCommand command,
        Stream input,
        CancellationToken cancellationToken
    )
    {
        string? trusted = await this.ReadOptionalAsync(path: command.TrustedFile, cancellationToken: cancellationToken);
        string json = await ReadAllAsync(input: input, cancellationToken: cancellationToken);

        if (command.Kind == FingerprintKind.ISSUE)
        {
            return this._fingerprints.Issue(
                issueJson: json,
                trustedLoginsJson: trusted,
                planApproved: command.PlanApproved,
                schemaVersion: command.SchemaVersion
            );
        }

        string? reviewComments = await this.ReadOptionalAsync(
            path: command.ReviewCommentsFile,
            cancellationToken: cancellationToken
        );

        return this._fingerprints.PullRequest(
            pullRequestJson: json,
            trustedLoginsJson: trusted,
            reviewCommentsJson: reviewComments,
            schemaVersion: command.SchemaVersion
        );
    }

    private async ValueTask<string?> ReadOptionalAsync(string? path, CancellationToken cancellationToken)
    {
        return path is null
            ? null
            : await this._files.ReadAllTextAsync(path: path, cancellationToken: cancellationToken);
    }

    private static async ValueTask<string> ReadAllAsync(Stream input, CancellationToken cancellationToken)
    {
        using MemoryStream buffer = new();
        await input.CopyToAsync(destination: buffer, cancellationToken: cancellationToken);

        return Utf8.GetString(buffer.ToArray());
    }

    private static bool IsHelp(string argument)
    {
        return StringComparer.Ordinal.Equals(x: argument, y: "--help")
            || StringComparer.Ordinal.Equals(x: argument, y: "-h");
    }

    private static async ValueTask<int> FailAsync(TextWriter error, string message, CancellationToken cancellationToken)
    {
        await error.WriteLineAsync($"{PROGRAM}: {message}".AsMemory(), cancellationToken);

        return ExitCodes.Failure;
    }
}
