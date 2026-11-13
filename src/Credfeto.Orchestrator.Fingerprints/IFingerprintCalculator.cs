namespace Credfeto.Orchestrator.Fingerprints;

public interface IFingerprintCalculator
{
    // fingerprint_pr_json (lib/fingerprints): trusted logins default to null (all activity counts), review comments to []
    string PullRequest(
        string pullRequestJson,
        string? trustedLoginsJson,
        string? reviewCommentsJson,
        int schemaVersion
    );

    // fingerprint_issue_json (lib/fingerprints): trusted logins default to null, plan approval to "false"
    string Issue(string issueJson, string? trustedLoginsJson, string? planApproved, int schemaVersion);
}
