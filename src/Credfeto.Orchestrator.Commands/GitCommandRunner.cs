using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Git;

namespace Credfeto.Orchestrator.Commands;

// credfeto-orchestrator git ...: answers a read-only lib/git query by running the same git commands, printing what the
// shell function prints, byte for byte, and exiting with the status it returns
public sealed class GitCommandRunner
{
    // The query cannot be answered exactly as bash would answer it, so lib/git answers it in bash
    public const int Refused = 3;

    // git could not be run, or the answer could not be written
    public const int Failed = 125;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator git head-sha|current-branch|uncommitted-changes --repo <dir>
               credfeto-orchestrator git porcelain-status|changed-file-count|stash-head --repo <dir>
               credfeto-orchestrator git origin-branch-exists --repo <dir> --branch <branch>
               credfeto-orchestrator git commits-behind --repo <dir> --ref <ref> --upstream <ref>
               credfeto-orchestrator git stale-issue-branch --repo <dir> --issue <number>
               credfeto-orchestrator git autostashes-beyond-keep --repo <dir> --prefix <prefix> --keep <count>

        Each query runs the git commands its lib/git function runs (git -C <dir>, so an empty --repo is the
        current directory), prints what the function prints and exits with the status it returns:
        head-sha checkout_head_sha, current-branch checkout_current_branch, uncommitted-changes
        checkout_has_uncommitted_changes (0 when there are changes), origin-branch-exists
        origin_branch_exists, commits-behind git_commits_behind, stale-issue-branch find_stale_issue_branch,
        porcelain-status checkout_porcelain_status, changed-file-count checkout_changed_file_count, stash-head
        checkout_stash_head and autostashes-beyond-keep autostashes_beyond_keep. git's stderr is passed through.

        Exit codes: 0, 1, 128 or 129 the answer; 2 a usage error; 3 the query cannot be answered exactly as bash
        would (an issue that is not a number, a branch name bash matches by the locale, a stash list that is not
        UTF-8, a prefix that is not plain letters, digits, '-' and '_', a keep that is not a decimal number), so
        lib/git answers it; 125 git could not be run.
        """;

    private readonly IGitQueries _queries;

    public GitCommandRunner(IGitQueries queries)
    {
        this._queries = queries;
    }

    public static GitCommandRunner CreateDefault()
    {
        return new(new GitQueries(new GitProcessRunner()));
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Stream output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        GitCommand? command = GitCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
            await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return ExitCodes.Usage;
        }

        try
        {
            GitResult answer = await this.AnswerAsync(command: command, cancellationToken: cancellationToken);
            await output.WriteAsync(answer.Output, cancellationToken);
            await output.FlushAsync(cancellationToken);

            return answer.ExitCode;
        }
        catch (GitRefusedException exception)
        {
            return await FailAsync(
                error: error,
                message: exception.Message,
                status: Refused,
                cancellationToken: cancellationToken
            );
        }
        catch (GitException exception)
        {
            return await FailAsync(
                error: error,
                message: exception.Message,
                status: Failed,
                cancellationToken: cancellationToken
            );
        }
        catch (IOException exception)
        {
            return await FailAsync(
                error: error,
                message: exception.Message,
                status: Failed,
                cancellationToken: cancellationToken
            );
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    private ValueTask<GitResult> AnswerAsync(GitCommand command, CancellationToken cancellationToken)
    {
        return command.Query switch
        {
            GitQuery.HEAD_SHA => this._queries.HeadShaAsync(
                repository: command.Repository,
                cancellationToken: cancellationToken
            ),
            GitQuery.CURRENT_BRANCH => this._queries.CurrentBranchAsync(
                repository: command.Repository,
                cancellationToken: cancellationToken
            ),
            GitQuery.UNCOMMITTED_CHANGES => this._queries.UncommittedChangesAsync(
                repository: command.Repository,
                cancellationToken: cancellationToken
            ),
            GitQuery.ORIGIN_BRANCH_EXISTS => this._queries.OriginBranchExistsAsync(
                repository: command.Repository,
                branch: command.Name,
                cancellationToken: cancellationToken
            ),
            GitQuery.COMMITS_BEHIND => this._queries.CommitsBehindAsync(
                repository: command.Repository,
                reference: command.Name,
                upstream: command.Upstream,
                cancellationToken: cancellationToken
            ),
            GitQuery.STALE_ISSUE_BRANCH => this._queries.StaleIssueBranchAsync(
                repository: command.Repository,
                issue: command.Name,
                cancellationToken: cancellationToken
            ),
            _ => this.AnswerStatusAsync(command: command, cancellationToken: cancellationToken),
        };
    }

    private ValueTask<GitResult> AnswerStatusAsync(GitCommand command, CancellationToken cancellationToken)
    {
        return command.Query switch
        {
            GitQuery.PORCELAIN_STATUS => this._queries.PorcelainStatusAsync(
                repository: command.Repository,
                cancellationToken: cancellationToken
            ),
            GitQuery.CHANGED_FILE_COUNT => this._queries.ChangedFileCountAsync(
                repository: command.Repository,
                cancellationToken: cancellationToken
            ),
            GitQuery.STASH_HEAD => this._queries.StashHeadAsync(
                repository: command.Repository,
                cancellationToken: cancellationToken
            ),
            _ => this._queries.AutostashesBeyondKeepAsync(
                repository: command.Repository,
                prefix: command.Name,
                keep: command.Keep,
                cancellationToken: cancellationToken
            ),
        };
    }

    private static async ValueTask<int> FailAsync(
        TextWriter error,
        string message,
        int status,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: git: {message}".AsMemory(), cancellationToken);

        return status;
    }
}
