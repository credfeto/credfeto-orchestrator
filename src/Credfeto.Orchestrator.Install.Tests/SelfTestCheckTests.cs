using System.Linq;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Install.Tests;

public sealed class SelfTestCheckTests : TestBase
{
    [Fact]
    public async Task EachBuiltInCheckPassesAsync()
    {
        ISelfTestCheck[] checks =
        [
            new ConfigSelfTest(),
            new JsonSelfTest(),
            new FingerprintSelfTest(new FingerprintCalculator()),
            new PromptTemplatesSelfTest(),
        ];

        foreach (ISelfTestCheck check in checks)
        {
            await check.RunAsync(this.CancellationToken());
        }

        Assert.Equal(
            expected: "config|json|fingerprint|prompt templates",
            actual: string.Join(separator: '|', values: checks.Select(check => check.Name))
        );
    }

    [Fact]
    public async Task AWrongFingerprintFailsTheCheckAsync()
    {
        FingerprintSelfTest check = new(new WrongFingerprintCalculator());

        SelfTestFailedException exception = await Assert.ThrowsAsync<SelfTestFailedException>(() =>
            check.RunAsync(this.CancellationToken()).AsTask()
        );

        Assert.StartsWith(
            expectedStartString: "pull request fingerprint: expected 2:",
            actualString: exception.Message,
            comparisonType: System.StringComparison.Ordinal
        );
        Assert.EndsWith(
            expectedEndString: ", got 2:wrong",
            actualString: exception.Message,
            comparisonType: System.StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task AFingerprintFailureFailsTheCheckAsync()
    {
        FingerprintSelfTest check = new(new ThrowingFingerprintCalculator());

        SelfTestFailedException exception = await Assert.ThrowsAsync<SelfTestFailedException>(() =>
            check.RunAsync(this.CancellationToken()).AsTask()
        );

        Assert.Equal(expected: "fingerprinting: bad input", actual: exception.Message);
    }

    private sealed class WrongFingerprintCalculator : IFingerprintCalculator
    {
        public string PullRequest(
            string pullRequestJson,
            string? trustedLoginsJson,
            string? reviewCommentsJson,
            int schemaVersion
        )
        {
            return "2:wrong";
        }

        public string Issue(string issueJson, string? trustedLoginsJson, string? planApproved, int schemaVersion)
        {
            return "2:wrong";
        }
    }

    private sealed class ThrowingFingerprintCalculator : IFingerprintCalculator
    {
        public string PullRequest(
            string pullRequestJson,
            string? trustedLoginsJson,
            string? reviewCommentsJson,
            int schemaVersion
        )
        {
            throw new FingerprintException("bad input");
        }

        public string Issue(string issueJson, string? trustedLoginsJson, string? planApproved, int schemaVersion)
        {
            throw new FingerprintException("bad input");
        }
    }
}
