using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Git;

// The read-only lib/git queries: each result is what the shell function prints and the status it returns
public interface IGitQueries
{
    // checkout_head_sha
    ValueTask<GitResult> HeadShaAsync(string repository, CancellationToken cancellationToken);

    // checkout_current_branch
    ValueTask<GitResult> CurrentBranchAsync(string repository, CancellationToken cancellationToken);

    // checkout_has_uncommitted_changes: status 0 when there are uncommitted changes
    ValueTask<GitResult> UncommittedChangesAsync(string repository, CancellationToken cancellationToken);

    // origin_branch_exists
    ValueTask<GitResult> OriginBranchExistsAsync(string repository, string branch, CancellationToken cancellationToken);

    // git_commits_behind
    ValueTask<GitResult> CommitsBehindAsync(
        string repository,
        string reference,
        string upstream,
        CancellationToken cancellationToken
    );

    // find_stale_issue_branch, after its own check that the checkout has a .git directory
    ValueTask<GitResult> StaleIssueBranchAsync(string repository, string issue, CancellationToken cancellationToken);

    // checkout_porcelain_status
    ValueTask<GitResult> PorcelainStatusAsync(string repository, CancellationToken cancellationToken);

    // checkout_changed_file_count
    ValueTask<GitResult> ChangedFileCountAsync(string repository, CancellationToken cancellationToken);

    // checkout_stash_head
    ValueTask<GitResult> StashHeadAsync(string repository, CancellationToken cancellationToken);

    // autostashes_beyond_keep
    ValueTask<GitResult> AutostashesBeyondKeepAsync(
        string repository,
        string prefix,
        string keep,
        CancellationToken cancellationToken
    );
}
