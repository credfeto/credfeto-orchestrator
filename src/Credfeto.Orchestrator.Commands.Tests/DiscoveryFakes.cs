using Credfeto.Orchestrator.Discovery;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Commands.Tests;

internal static class DiscoveryFakes
{
    // Discovery commands over the given fakes: each URL read takes the next of urls' bodies, the collaborators come
    // from github
    public static DiscoveryCommandRunner Runner(FakeUrlReader urls, FakeRetryDelay delay, IGitHubReader github)
    {
        return new(
            priorities: new PriorityFeed(urls: urls, delay: delay),
            trustedLogins: new TrustedLoginsReader(github: github, delay: delay),
            health: new GitHubIncidentGate(urls)
        );
    }

    // For the runners of the other commands, which never read a URL
    public static DiscoveryCommandRunner NotExpected(IGitHubReader github)
    {
        return Runner(urls: new(), delay: new(), github: github);
    }
}
