using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Fingerprints.Tests;

public sealed class FingerprintCalculatorTests : TestBase
{
    private const string PULL_REQUEST =
        """{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}""";
    private const string ISSUE =
        """{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}""";

    private static readonly IFingerprintCalculator Calculator = new FingerprintCalculator();

    [Fact]
    public static void IssueFingerprintMatchesTheValueTheShellTestsPin()
    {
        string fingerprint = Calculator.Issue(
            issueJson: ISSUE,
            trustedLoginsJson: "null",
            planApproved: "false",
            schemaVersion: FingerprintSchema.Version
        );

        Assert.Equal(
            expected: "2:36d5acf9d9297f831145e17ec71ce45fcbd20d60b9af5b25ef6773cacbdc5116",
            actual: fingerprint
        );
    }

    [Fact]
    public static void TheSchemaVersionPrefixesTheFingerprint()
    {
        string current = Calculator.PullRequest(
            pullRequestJson: PULL_REQUEST,
            trustedLoginsJson: null,
            reviewCommentsJson: null,
            schemaVersion: FingerprintSchema.Version
        );
        string next = Calculator.PullRequest(
            pullRequestJson: PULL_REQUEST,
            trustedLoginsJson: null,
            reviewCommentsJson: null,
            schemaVersion: FingerprintSchema.Version + 1
        );

        Assert.StartsWith(
            expectedStartString: "2:",
            actualString: current,
            comparisonType: System.StringComparison.Ordinal
        );
        Assert.StartsWith(
            expectedStartString: "3:",
            actualString: next,
            comparisonType: System.StringComparison.Ordinal
        );
        Assert.Equal(expected: current[2..], actual: next[2..]);
    }

    [Fact]
    public static void OmittedOptionalInputsMatchTheShellDefaults()
    {
        string omitted = Calculator.PullRequest(
            pullRequestJson: PULL_REQUEST,
            trustedLoginsJson: null,
            reviewCommentsJson: string.Empty,
            schemaVersion: FingerprintSchema.Version
        );
        string explicitDefaults = Calculator.PullRequest(
            pullRequestJson: PULL_REQUEST,
            trustedLoginsJson: "null",
            reviewCommentsJson: "[]",
            schemaVersion: FingerprintSchema.Version
        );

        Assert.Equal(expected: explicitDefaults, actual: omitted);
        Assert.Equal(
            expected: Calculator.Issue(
                issueJson: ISSUE,
                trustedLoginsJson: "null",
                planApproved: "false",
                schemaVersion: FingerprintSchema.Version
            ),
            actual: Calculator.Issue(
                issueJson: ISSUE,
                trustedLoginsJson: string.Empty,
                planApproved: null,
                schemaVersion: FingerprintSchema.Version
            )
        );
    }

    [Fact]
    public static void InlineReviewCommentsBeyondTheArgumentSizeLimitAreFingerprinted()
    {
        string reviewComments =
            "[{\"user\":{\"login\":\"bob\"},\"updated_at\":\"t\",\"body\":\""
            + new string(c: 'a', count: 200_000)
            + "\"}]";

        string fingerprint = Calculator.PullRequest(
            pullRequestJson: PULL_REQUEST,
            trustedLoginsJson: null,
            reviewCommentsJson: reviewComments,
            schemaVersion: FingerprintSchema.Version
        );

        Assert.StartsWith(
            expectedStartString: "2:",
            actualString: fingerprint,
            comparisonType: System.StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData("""{"title":"\ud800x"}""")]
    [InlineData("""{"title":"\ud800"}""")]
    public static void AHighSurrogateWithoutItsPairFailsAsInJq(string json)
    {
        Assert.Throws<FingerprintException>(() =>
            Calculator.Issue(
                issueJson: json,
                trustedLoginsJson: null,
                planApproved: null,
                schemaVersion: FingerprintSchema.Version
            )
        );
    }

    [Fact]
    public static void ALowSurrogateWithoutItsPairReadsAsTheReplacementCharacterAsInJq()
    {
        string lone = Calculator.Issue(
            issueJson: """{"title":"\udc00"}""",
            trustedLoginsJson: null,
            planApproved: null,
            schemaVersion: FingerprintSchema.Version
        );
        string replacement = Calculator.Issue(
            issueJson: """{"title":"�"}""",
            trustedLoginsJson: null,
            planApproved: null,
            schemaVersion: FingerprintSchema.Version
        );

        Assert.Equal(expected: replacement, actual: lone);
    }

    [Fact]
    public static void TrustedLoginsThatAreNotAnArrayFailOnceThereIsActivityToFilter()
    {
        const string withComment = """{"title":"T","comments":[{"author":{"login":"owner"},"body":"x"}]}""";

        Assert.Throws<FingerprintException>(() =>
            Calculator.PullRequest(
                pullRequestJson: withComment,
                trustedLoginsJson: "\"owner\"",
                reviewCommentsJson: null,
                schemaVersion: FingerprintSchema.Version
            )
        );
    }
}
