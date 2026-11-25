using System;
using Credfeto.Orchestrator.Discovery;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class DiscoveryCommandParserTests : TestBase
{
    private static readonly RetryPolicy DefaultRetry = new(Attempts: 3, Delay: TimeSpan.FromSeconds(2));

    [Fact]
    public static void PrioritiesTakeTheUrlLoginAndRetrySettings()
    {
        DiscoveryCommand? command = Parse(
            "discovery",
            "priorities",
            "--url",
            "https://feed.example/priorities",
            "--user",
            "me",
            "--attempts",
            "5",
            "--delay-secs",
            "0"
        );

        Assert.NotNull(command);
        Assert.Equal(expected: DiscoveryRead.PRIORITIES, actual: command.Read);
        Assert.Equal(expected: "https://feed.example/priorities", actual: command.Endpoint);
        Assert.Equal(expected: "me", actual: command.User);
        Assert.Equal(expected: new(Attempts: 5, Delay: TimeSpan.Zero), actual: command.Retry);
    }

    [Theory]
    [InlineData("discovery|priorities|--url|https://feed.example/p")]
    [InlineData("discovery|priorities|--url|https://feed.example/p|--user|")]
    public static void PrioritiesWithoutALoginOrRetrySettingsUseNoneAndTheDefaults(string args)
    {
        DiscoveryCommand? command = Parse(args.Split('|'));

        Assert.NotNull(command);
        Assert.Null(command.User);
        Assert.Equal(expected: DefaultRetry, actual: command.Retry);
    }

    [Fact]
    public static void TrustedLoginsTakeTheRepositoryOwnerWhitelistAndCreator()
    {
        DiscoveryCommand? command = Parse(
            "discovery",
            "trusted-logins",
            "--repo",
            "org/repo",
            "--owner",
            "org",
            "--whitelist",
            " a, b",
            "--creator",
            "prpixie",
            "--attempts",
            "2"
        );

        Assert.NotNull(command);
        Assert.Equal(expected: DiscoveryRead.TRUSTED_LOGINS, actual: command.Read);
        Assert.Equal(
            expected: new(Repository: "org/repo", Owner: "org", Whitelist: " a, b", Creator: "prpixie"),
            actual: command.TrustedLogins
        );
        Assert.Equal(expected: new(Attempts: 2, Delay: TimeSpan.FromSeconds(2)), actual: command.Retry);
    }

    [Fact]
    public static void TrustedLoginsDefaultToNoOwnerWhitelistOrCreator()
    {
        DiscoveryCommand? command = Parse("discovery", "trusted-logins", "--repo", "org/repo", "--owner", "");

        Assert.NotNull(command);
        Assert.Equal(
            expected: new(Repository: "org/repo", Owner: "", Whitelist: "", Creator: ""),
            actual: command.TrustedLogins
        );
    }

    [Fact]
    public static void TheGitHubIncidentListsDefaultToLibGlobals()
    {
        DiscoveryCommand? command = Parse("discovery", "github-incident", "--url", "file:///tmp/status.json");

        Assert.NotNull(command);
        Assert.Equal(expected: DiscoveryRead.GITHUB_INCIDENT, actual: command.Read);
        Assert.Same(expected: GitHubHealthRules.Default.Components, actual: command.Rules.Components);
        Assert.Same(expected: GitHubHealthRules.Default.SeriousImpacts, actual: command.Rules.SeriousImpacts);
        Assert.Same(expected: GitHubHealthRules.Default.OutageStatuses, actual: command.Rules.OutageStatuses);
    }

    [Fact]
    public static void AGitHubIncidentListGivenReplacesItsDefault()
    {
        DiscoveryCommand? command = Parse(
            "discovery",
            "github-incident",
            "--url",
            "https://status.example/summary.json",
            "--component",
            "Issues",
            "--component",
            "Git Operations",
            "--outage-status",
            "major_outage"
        );

        Assert.NotNull(command);
        Assert.Equal(expected: ["Issues", "Git Operations"], actual: command.Rules.Components);
        Assert.Same(expected: GitHubHealthRules.Default.SeriousImpacts, actual: command.Rules.SeriousImpacts);
        Assert.Equal(expected: ["major_outage"], actual: command.Rules.OutageStatuses);
    }

    [Fact]
    public static void TheLastValueOfASingleOptionIsTaken()
    {
        DiscoveryCommand? command = Parse(
            "discovery",
            "priorities",
            "--url",
            "https://a.example",
            "--url",
            "https://b.example"
        );

        Assert.NotNull(command);
        Assert.Equal(expected: "https://b.example", actual: command.Endpoint);
    }

    [Theory]
    [InlineData("expected: discovery priorities|trusted-logins|github-incident [options]", "discovery")]
    [InlineData("expected: discovery priorities|trusted-logins|github-incident [options]", "github|priorities")]
    [InlineData(
        "unknown discovery read 'feed': expected priorities, trusted-logins or github-incident",
        "discovery|feed"
    )]
    [InlineData("--url is required", "discovery|priorities")]
    [InlineData("--url is required", "discovery|priorities|--url|")]
    [InlineData("--url needs a value", "discovery|priorities|--url")]
    [InlineData("unknown option '--repo'", "discovery|priorities|--repo|org/repo")]
    [InlineData("unknown option '--user'", "discovery|github-incident|--user|me")]
    [InlineData("--repo is required", "discovery|trusted-logins|--owner|org")]
    [InlineData("--url is required", "discovery|github-incident")]
    [InlineData("--url must be an absolute URL", "discovery|github-incident|--url|summary.json")]
    public static void AnInvalidCommandIsAUsageError(string expected, string args)
    {
        Assert.Null(DiscoveryCommandParser.Parse(args: args.Split('|'), error: out string error));
        Assert.Equal(expected: expected, actual: error);
    }

    [Theory]
    [InlineData("--attempts", "0", "--attempts must be a whole number from 1")]
    [InlineData("--attempts", "-1", "--attempts must be a whole number from 1")]
    [InlineData("--attempts", "x", "--attempts must be a whole number from 1")]
    [InlineData("--attempts", "", "--attempts must be a whole number from 1")]
    [InlineData("--attempts", "99999999999", "--attempts must be a whole number from 1")]
    [InlineData("--delay-secs", "-2", "--delay-secs must be a whole number")]
    [InlineData("--delay-secs", "1.5", "--delay-secs must be a whole number")]
    public static void AnInvalidRetrySettingIsAUsageError(string option, string value, string expected)
    {
        Assert.Null(
            DiscoveryCommandParser.Parse(
                args: ["discovery", "trusted-logins", "--repo", "org/repo", option, value],
                error: out string error
            )
        );
        Assert.Equal(expected: expected, actual: error);
        Assert.Null(
            DiscoveryCommandParser.Parse(
                args: ["discovery", "priorities", "--url", "https://feed.example", option, value],
                error: out error
            )
        );
        Assert.Equal(expected: expected, actual: error);
    }

    private static DiscoveryCommand? Parse(params string[] args)
    {
        DiscoveryCommand? command = DiscoveryCommandParser.Parse(args: args, error: out string error);
        Assert.Equal(expected: string.Empty, actual: error);

        return command;
    }
}
