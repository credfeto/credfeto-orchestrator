using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Fingerprints;

// The per-item state files lib/fingerprints keeps in the session directory
public interface IFingerprintStateStore
{
    string PullRequestFingerprintPath(string itemId);

    string IssueFingerprintPath(string itemId);

    string PullRequestHeadOidPath(string itemId);

    string PullRequestUnknownMergeStatePath(string itemId);

    string PullRequestLastAgentCommentPath(string itemId);

    ValueTask SavePullRequestFingerprintAsync(string itemId, string fingerprint, CancellationToken cancellationToken);

    ValueTask<string> LoadPullRequestFingerprintAsync(string itemId, CancellationToken cancellationToken);

    ValueTask SaveIssueFingerprintAsync(string itemId, string fingerprint, CancellationToken cancellationToken);

    ValueTask<string> LoadIssueFingerprintAsync(string itemId, CancellationToken cancellationToken);

    ValueTask SavePullRequestHeadOidAsync(
        string itemId,
        string oid,
        long timestamp,
        CancellationToken cancellationToken
    );

    ValueTask<string> LoadPullRequestHeadOidAsync(string itemId, CancellationToken cancellationToken);

    ValueTask<bool> CiChecksTimedOutAsync(
        string itemId,
        string pullRequestJson,
        int timeoutMinutes,
        CancellationToken cancellationToken
    );

    void ClearPullRequestCiPendingState(string itemId);

    ValueTask SavePullRequestUnknownMergeStateSinceAsync(
        string itemId,
        long timestamp,
        CancellationToken cancellationToken
    );

    void ClearPullRequestUnknownMergeState(string itemId);

    ValueTask<bool> PullRequestUnknownMergeStateTimedOutAsync(
        string itemId,
        string mergeState,
        int timeoutMinutes,
        CancellationToken cancellationToken
    );

    ValueTask SavePullRequestLastAgentCommentSeenAsync(
        string itemId,
        string timestamp,
        CancellationToken cancellationToken
    );

    ValueTask<string> LoadPullRequestLastAgentCommentSeenAsync(string itemId, CancellationToken cancellationToken);
}
