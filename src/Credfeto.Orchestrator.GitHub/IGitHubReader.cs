using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.GitHub;

public interface IGitHubReader
{
    // The numbers of the open pull requests whose head branch is exactly head, a fork's included, newest first as gh
    // pr list orders them
    ValueTask<IReadOnlyList<int>> OpenPullRequestsOnHeadAsync(
        string repository,
        string head,
        CancellationToken cancellationToken
    );

    // Whether the branch requires any status check, through classic branch protection or a ruleset
    ValueTask<bool> BranchRequiresStatusChecksAsync(
        string repository,
        string branch,
        CancellationToken cancellationToken
    );

    // The numbers of the open pull requests the orchestrator itself opened (authored by me or by the pull request bot,
    // creator, compared case-insensitively), leaving out those labelled Blocked unless includeBlocked, newest first as
    // list_bot_created_open_prs prints them
    ValueTask<IReadOnlyList<int>> OwnOpenPullRequestsAsync(
        string repository,
        string me,
        string creator,
        bool includeBlocked,
        CancellationToken cancellationToken
    );

    // The login the GitHub token authenticates as, as gh api user prints it; empty when GitHub gives none
    ValueTask<string> CurrentLoginAsync(CancellationToken cancellationToken);

    // Every open pull request with its author, the issues it closes and its head branch, newest first as gh pr list
    // orders them
    ValueTask<IReadOnlyList<OpenPullRequestReferences>> OpenPullRequestsWithClosingIssuesAsync(
        string repository,
        CancellationToken cancellationToken
    );

    // The authors and co-authors of every commit on the pull request
    ValueTask<IReadOnlyList<PullRequestCommit>> PullRequestCommitsAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    );

    // How many of the base branch's commits the head branch lacks, counted from their merge base
    ValueTask<int> BranchBehindByAsync(
        string repository,
        string baseBranch,
        string headBranch,
        CancellationToken cancellationToken
    );

    // Every top-level comment and every inline review comment on the pull request, with whole bodies
    ValueTask<PullRequestComments> PullRequestCommentsAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    );

    // The numbers of the issues the pull request closes, in any repository, in GitHub's order
    ValueTask<IReadOnlyList<int>> PullRequestClosingIssuesAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    );

    // The labels of every issue the pull request closes that could be read, leaving out Blocked, On Hold and On-Hold
    // in any case
    ValueTask<IReadOnlyList<string>> ClosingIssueLabelsAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    );

    // The logins of the repository's collaborators, in the server's order (by login), as gh api
    // repos/<repo>/collaborators --paginate --jq '.[].login' lists them for get_trusted_logins
    ValueTask<IReadOnlyList<string>> RepositoryCollaboratorsAsync(
        string repository,
        CancellationToken cancellationToken
    );

    // Every check run and status context on the pull request's head commit, every page, with GitHub's own answer to
    // whether it is required for merging this pull request (the isRequired(pullRequestNumber:) field
    // fetch_pr_required_check_names reads); throws McpServerOutdatedException when the server gives no such answer
    ValueTask<IReadOnlyList<PullRequestCheck>> PullRequestChecksAsync(
        string repository,
        int pullRequest,
        CancellationToken cancellationToken
    );

    // How many check runs on the commit are still running: no conclusion and a queued, in_progress, waiting, pending
    // or requested status, over every run GitHub's default (latest) filter lists, as head_commit_has_running_check_runs
    // reads them; throws McpServerOutdatedException when the server does not list commit_check_runs
    ValueTask<int> CommitRunningCheckRunsAsync(string repository, string sha, CancellationToken cancellationToken);
}
