using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.GitHub;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Commands;

// Runs the checks reads that ask GitHub, through the cfwf MCP server, printing and returning what the lib/github
// function each replaces prints and returns, or refusing (Refused) when the server is older than the read needs, so
// bash answers instead
public sealed class ChecksReadCommandRunner
{
    // The server is older than the read needs: pr_view's checks carry no required flag, or commit_check_runs is not
    // listed
    public const int Refused = 3;

    // has-running-check-runs, as head_commit_has_running_check_runs returns: a check run is still running, none is,
    // or the lookup failed (an empty --repo or --sha included)
    public const int Running = 0;
    public const int NotRunning = 1;
    public const int LookupFailed = 2;

    private const string PROGRAM = "credfeto-orchestrator";

    // pr_view reads every page of checks; the GraphQL query the shell version makes reads one page of 100 and fails
    // past it, so the tool does too
    private const int SHELL_PAGE = 100;

    private readonly IGitHubReader _github;

    public ChecksReadCommandRunner(IGitHubReader github)
    {
        this._github = github;
    }

    public ValueTask<int> RunAsync(
        ChecksReadCommand command,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        return command.Read == ChecksRead.REQUIRED_CHECK_NAMES
            ? this.RequiredCheckNamesAsync(
                command: command,
                output: output,
                error: error,
                cancellationToken: cancellationToken
            )
            : this.HasRunningCheckRunsAsync(command: command, error: error, cancellationToken: cancellationToken);
    }

    // The names of the checks GitHub requires for merging the pull request, as fetch_pr_required_check_names prints
    // them: one line of JSON, unique and sorted by code point as jq's unique leaves them
    public static string RequiredCheckNames(IReadOnlyList<PullRequestCheck> checks)
    {
        IEnumerable<JqValue> names = checks
            .Where(check => check.Required)
            .Select(check => check.Name)
            .Distinct(StringComparer.Ordinal)
            .Order(JqStringComparer.Instance)
            .Select(JqValue.FromString);

        return JqFormatter.ToJson(JqValue.FromArray([.. names])) + "\n";
    }

    private async ValueTask<int> RequiredCheckNamesAsync(
        ChecksReadCommand command,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        try
        {
            IReadOnlyList<PullRequestCheck> checks = await this._github.PullRequestChecksAsync(
                repository: command.Repository,
                pullRequest: command.PullRequest,
                cancellationToken: cancellationToken
            );

            if (checks.Count > SHELL_PAGE)
            {
                return await ProblemAsync(
                    error: error,
                    message: string.Create(
                        provider: CultureInfo.InvariantCulture,
                        $"the pull request has {checks.Count} checks, more than the shell version reads"
                    ),
                    exitCode: ExitCodes.Failure,
                    cancellationToken: cancellationToken
                );
            }

            await output.WriteAsync(RequiredCheckNames(checks).AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            return ExitCodes.Success;
        }
        catch (McpServerOutdatedException exception)
        {
            return await ProblemAsync(
                error: error,
                message: exception.Message,
                exitCode: Refused,
                cancellationToken: cancellationToken
            );
        }
        catch (GitHubReadException exception)
        {
            return await ProblemAsync(
                error: error,
                message: exception.Message,
                exitCode: ExitCodes.Failure,
                cancellationToken: cancellationToken
            );
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    private async ValueTask<int> HasRunningCheckRunsAsync(
        ChecksReadCommand command,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        // The shell version's guard: nothing is asked without a repository and a commit
        if (command.Repository.Length == 0 || command.Sha.Length == 0)
        {
            return LookupFailed;
        }

        try
        {
            int running = await this._github.CommitRunningCheckRunsAsync(
                repository: command.Repository,
                sha: command.Sha,
                cancellationToken: cancellationToken
            );

            return running > 0 ? Running : NotRunning;
        }
        catch (McpServerOutdatedException exception)
        {
            return await ProblemAsync(
                error: error,
                message: exception.Message,
                exitCode: Refused,
                cancellationToken: cancellationToken
            );
        }
        catch (GitHubReadException exception)
        {
            return await ProblemAsync(
                error: error,
                message: exception.Message,
                exitCode: LookupFailed,
                cancellationToken: cancellationToken
            );
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    private static async ValueTask<int> ProblemAsync(
        TextWriter error,
        string message,
        int exitCode,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: {message}".AsMemory(), cancellationToken);

        return exitCode;
    }
}
