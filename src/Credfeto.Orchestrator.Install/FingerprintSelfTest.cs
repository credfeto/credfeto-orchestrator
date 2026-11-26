using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;

namespace Credfeto.Orchestrator.Install;

// A tiny pull request fingerprints to the value fingerprint_pr_json (lib/fingerprints) gives it with its default
// trusted logins (null) and review comments ([])
public sealed class FingerprintSelfTest : ISelfTestCheck
{
    private const int SCHEMA_VERSION = 2;

    private const string PULL_REQUEST = """
        {"number":1,"headRefOid":"0123abc","mergeStateStatus":"CLEAN","labels":[{"name":"Enhancement"}]}
        """;

    private const string EXPECTED = "2:c8d2a228a329f1f0debaa143b601ddcdc6cbb08ee336c538024573622a8da8ea";

    private readonly IFingerprintCalculator _fingerprints;

    public FingerprintSelfTest(IFingerprintCalculator fingerprints)
    {
        this._fingerprints = fingerprints;
    }

    public string Name => "fingerprint";

    public ValueTask RunAsync(CancellationToken cancellationToken)
    {
        string actual;

        try
        {
            actual = this._fingerprints.PullRequest(
                pullRequestJson: PULL_REQUEST,
                trustedLoginsJson: null,
                reviewCommentsJson: "[]",
                schemaVersion: SCHEMA_VERSION
            );
        }
        catch (FingerprintException exception)
        {
            throw new SelfTestFailedException(
                message: "fingerprinting: " + exception.Message,
                innerException: exception
            );
        }

        SelfTestExpect.Same(what: "pull request fingerprint", expected: EXPECTED, actual: actual);

        return ValueTask.CompletedTask;
    }
}
