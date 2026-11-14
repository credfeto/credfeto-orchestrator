using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Commands;

public sealed class CommandRunner
{
    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator fingerprint pr [--trusted-file <file>] [--review-comments-file <file>] [--schema-version <n>]
               credfeto-orchestrator fingerprint issue [--trusted-file <file>] [--plan-approved <value>] [--schema-version <n>]
               credfeto-orchestrator github open-prs|open-pr-count --repo <owner/repo> --head <branch>
               credfeto-orchestrator github branch-requires-status-checks --repo <owner/repo> --branch <branch>

        fingerprint reads the pull request or issue JSON on stdin and prints its fingerprint, exactly
        as fingerprint_pr_json / fingerprint_issue_json in lib/fingerprints do.

        github asks the cfwf MCP server (ORCHESTRATOR_CFWF_MCP_URL, with the token in
        GH_ENTERPRISE_TOKEN or GH_TOKEN) and prints what the gh call in lib/github it replaces prints:
        open-prs the numbers of the open pull requests on the head branch, newest first, one a line;
        open-pr-count how many there are; branch-requires-status-checks true or false.

        Exit codes: 0 printed; 1 the fingerprint could not be computed or the read failed; 2 a usage
        error.
        """;

    private static readonly Encoding Utf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    private readonly IFileContentReader _files;
    private readonly IFingerprintCalculator _fingerprints;
    private readonly IGitHubReader _github;

    public CommandRunner(IFingerprintCalculator fingerprints, IFileContentReader files, IGitHubReader github)
    {
        this._fingerprints = fingerprints;
        this._files = files;
        this._github = github;
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

        if (args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: GitHubCommandParser.Verb))
        {
            return await this.RunGitHubAsync(
                args: args,
                output: output,
                error: error,
                cancellationToken: cancellationToken
            );
        }

        FingerprintCommand? command = FingerprintCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return await UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
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

    private async ValueTask<int> RunGitHubAsync(
        IReadOnlyList<string> args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        GitHubCommand? command = GitHubCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return await UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        try
        {
            string printed = await this.ReadGitHubAsync(command: command, cancellationToken: cancellationToken);
            await output.WriteAsync(printed.AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            return ExitCodes.Success;
        }
        catch (GitHubReadException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    // Each prints what the gh call it replaces prints: gh's --jq output ends every value with a newline
    private async ValueTask<string> ReadGitHubAsync(GitHubCommand command, CancellationToken cancellationToken)
    {
        if (command.Read == GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS)
        {
            bool required = await this._github.BranchRequiresStatusChecksAsync(
                repository: command.Repository,
                branch: command.Name,
                cancellationToken: cancellationToken
            );

            return required ? "true\n" : "false\n";
        }

        IReadOnlyList<int> numbers = await this._github.OpenPullRequestsOnHeadAsync(
            repository: command.Repository,
            head: command.Name,
            cancellationToken: cancellationToken
        );

        return command.Read == GitHubRead.OPEN_PULL_REQUEST_COUNT
            ? Line(numbers.Count)
            : string.Concat(numbers.Select(Line));
    }

    private static string Line(int value)
    {
        return value.ToString(CultureInfo.InvariantCulture) + "\n";
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

    private static async ValueTask<int> UsageAsync(
        TextWriter error,
        string problem,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
        await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

        return ExitCodes.Usage;
    }

    private static async ValueTask<int> FailAsync(TextWriter error, string message, CancellationToken cancellationToken)
    {
        await error.WriteLineAsync($"{PROGRAM}: {message}".AsMemory(), cancellationToken);

        return ExitCodes.Failure;
    }
}
