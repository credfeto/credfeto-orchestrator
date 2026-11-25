using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Git;

namespace Credfeto.Orchestrator.Commands.Tests;

// Gives one scripted answer (or failure) to every query, and records each query with its arguments
internal sealed class FakeGitQueries : IGitQueries
{
    private readonly Exception? _failure;
    private readonly GitResult _result;
    private readonly List<string> _asked = [];

    public FakeGitQueries(int exitCode, string output, Exception? failure = null)
    {
        this._result = new(ExitCode: exitCode, Output: Encoding.UTF8.GetBytes(output));
        this._failure = failure;
    }

    public IReadOnlyList<string> Asked => this._asked;

    public ValueTask<GitResult> HeadShaAsync(string repository, CancellationToken cancellationToken)
    {
        return this.AnswerAsync($"head-sha {repository}");
    }

    public ValueTask<GitResult> CurrentBranchAsync(string repository, CancellationToken cancellationToken)
    {
        return this.AnswerAsync($"current-branch {repository}");
    }

    public ValueTask<GitResult> UncommittedChangesAsync(string repository, CancellationToken cancellationToken)
    {
        return this.AnswerAsync($"uncommitted-changes {repository}");
    }

    public ValueTask<GitResult> OriginBranchExistsAsync(
        string repository,
        string branch,
        CancellationToken cancellationToken
    )
    {
        return this.AnswerAsync($"origin-branch-exists {repository} {branch}");
    }

    public ValueTask<GitResult> CommitsBehindAsync(
        string repository,
        string reference,
        string upstream,
        CancellationToken cancellationToken
    )
    {
        return this.AnswerAsync($"commits-behind {repository} {reference} {upstream}");
    }

    public ValueTask<GitResult> StaleIssueBranchAsync(
        string repository,
        string issue,
        CancellationToken cancellationToken
    )
    {
        return this.AnswerAsync($"stale-issue-branch {repository} {issue}");
    }

    public ValueTask<GitResult> PorcelainStatusAsync(string repository, CancellationToken cancellationToken)
    {
        return this.AnswerAsync($"porcelain-status {repository}");
    }

    public ValueTask<GitResult> ChangedFileCountAsync(string repository, CancellationToken cancellationToken)
    {
        return this.AnswerAsync($"changed-file-count {repository}");
    }

    public ValueTask<GitResult> StashHeadAsync(string repository, CancellationToken cancellationToken)
    {
        return this.AnswerAsync($"stash-head {repository}");
    }

    public ValueTask<GitResult> AutostashesBeyondKeepAsync(
        string repository,
        string prefix,
        string keep,
        CancellationToken cancellationToken
    )
    {
        return this.AnswerAsync($"autostashes-beyond-keep {repository} {prefix} {keep}");
    }

    private ValueTask<GitResult> AnswerAsync(string asked)
    {
        this._asked.Add(asked);

        return this._failure is null
            ? ValueTask.FromResult(this._result)
            : ValueTask.FromException<GitResult>(this._failure);
    }
}
