using System;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class GitHubIncidentGateTests : TestBase
{
    private static readonly Uri Status = new("https://status.example/api/v2/summary.json");

    [Fact]
    public async Task TheStatusIsReadFollowingRedirectsWithCurlsTimeoutsAsync()
    {
        FakeUrlReader urls = new("""{"incidents":[]}""");

        GitHubIncident incident = await new GitHubIncidentGate(urls).CheckAsync(
            url: Status,
            rules: GitHubHealthRules.Default,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: GitHubIncidentKind.NONE, actual: incident.Kind);
        Assert.Equal(
            expected: new(
                Url: Status,
                FollowRedirects: true,
                ConnectTimeout: TimeSpan.FromSeconds(5),
                MaxTime: TimeSpan.FromSeconds(10)
            ),
            actual: Assert.Single(urls.Requests)
        );
    }

    [Fact]
    public async Task AStatusThatCannotBeReadIsUnreadableAsync()
    {
        GitHubIncident incident = await new GitHubIncidentGate(new FakeUrlReader()).CheckAsync(
            url: Status,
            rules: GitHubHealthRules.Default,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: GitHubIncidentKind.UNREADABLE, actual: incident.Kind);
        Assert.Equal(expected: string.Empty, actual: incident.Line);
        Assert.Equal(expected: Status + " could not be read: refused", actual: incident.Problem);
    }

    [Fact]
    public async Task AStatusThatIsNotTheExpectedJsonIsUnreadableAsync()
    {
        GitHubIncident incident = await new GitHubIncidentGate(new FakeUrlReader("[]")).CheckAsync(
            url: Status,
            rules: GitHubHealthRules.Default,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: GitHubIncidentKind.UNREADABLE, actual: incident.Kind);
        Assert.Equal(expected: "the status is not the expected JSON: unexpected status JSON", actual: incident.Problem);
    }
}
