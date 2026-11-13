using System;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Fingerprints.Tests;

public sealed class FingerprintParityTests : TestBase
{
    private static readonly IFingerprintCalculator Calculator = new FingerprintCalculator();

    public static Task<TheoryData<int, string>> PullRequestCasesAsync()
    {
        return ParityFixture.CaseNamesAsync(ParityFixture.PullRequests);
    }

    public static Task<TheoryData<int, string>> IssueCasesAsync()
    {
        return ParityFixture.CaseNamesAsync(ParityFixture.Issues);
    }

    [Theory]
    [MemberData(nameof(PullRequestCasesAsync))]
    public async Task PullRequestMatchesTheShellVersionAsync(int index, string name)
    {
        ParityCase parity = await ParityFixture.CaseAsync(
            collection: ParityFixture.PullRequests,
            index: index,
            cancellationToken: this.CancellationToken()
        );

        string? actual = Compute(() =>
            Calculator.PullRequest(
                pullRequestJson: parity.Item,
                trustedLoginsJson: parity.Trusted,
                reviewCommentsJson: parity.ReviewComments,
                schemaVersion: FingerprintSchema.Version
            )
        );

        Assert.Equal(
            expected: Describe(name: name, fingerprint: parity.Expected),
            actual: Describe(name: name, fingerprint: actual)
        );
    }

    [Theory]
    [MemberData(nameof(IssueCasesAsync))]
    public async Task IssueMatchesTheShellVersionAsync(int index, string name)
    {
        ParityCase parity = await ParityFixture.CaseAsync(
            collection: ParityFixture.Issues,
            index: index,
            cancellationToken: this.CancellationToken()
        );

        string? actual = Compute(() =>
            Calculator.Issue(
                issueJson: parity.Item,
                trustedLoginsJson: parity.Trusted,
                planApproved: parity.PlanApproved,
                schemaVersion: FingerprintSchema.Version
            )
        );

        Assert.Equal(
            expected: Describe(name: name, fingerprint: parity.Expected),
            actual: Describe(name: name, fingerprint: actual)
        );
    }

    private static string? Compute(Func<string> fingerprint)
    {
        try
        {
            return fingerprint();
        }
        catch (FingerprintException)
        {
            return null;
        }
    }

    private static string Describe(string name, string? fingerprint)
    {
        return name + ": " + (fingerprint ?? "fails");
    }
}
