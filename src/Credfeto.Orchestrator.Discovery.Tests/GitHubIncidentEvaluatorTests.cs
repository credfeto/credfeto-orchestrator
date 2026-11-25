using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class GitHubIncidentEvaluatorTests : TestBase
{
    [Fact]
    public static void AMajorIncidentOnAUsedComponentIsSerious()
    {
        GitHubIncident incident = Evaluate(
            """{"incidents":[{"name":"Git is down","impact":"major","created_at":"t1","components":[{"name":"Git Operations"}]}]}"""
        );

        Assert.Equal(expected: new(Kind: GitHubIncidentKind.SERIOUS, Line: "Git is down\tt1"), actual: incident);
    }

    [Fact]
    public static void AMinorIncidentNamesItsFirstUsedComponentAndItsLiveStatus()
    {
        GitHubIncident incident = Evaluate(
            """{"components":[{"name":"Issues","status":"degraded_performance"}],"incidents":[{"name":"Slow","impact":"minor","created_at":"t1","components":[{"name":"Copilot"},{"name":"Issues"}]}]}"""
        );

        Assert.Equal(
            expected: new(Kind: GitHubIncidentKind.MINOR, Line: "Slow\tt1\tIssues: degraded_performance"),
            actual: incident
        );
    }

    [Fact]
    public static void AnOutageOfAUsedComponentMakesAMinorIncidentSerious()
    {
        GitHubIncident incident = Evaluate(
            """{"components":[{"name":"Issues","status":"partial_outage"}],"incidents":[{"name":"Slow","impact":"minor","created_at":"t1","components":[{"name":"Issues"}]}]}"""
        );

        Assert.Equal(expected: GitHubIncidentKind.SERIOUS, actual: incident.Kind);
    }

    [Fact]
    public static void TheRulesGivenAreTheOnesUsed()
    {
        GitHubHealthRules rules = new(Components: ["Copilot"], SeriousImpacts: ["minor"], OutageStatuses: []);

        GitHubIncident incident = GitHubIncidentEvaluator.Evaluate(
            json: """{"incidents":[{"name":"Copilot slow","impact":"minor","created_at":"t1","components":[{"name":"Copilot"}]}]}""",
            rules: rules
        );

        Assert.Equal(expected: new(Kind: GitHubIncidentKind.SERIOUS, Line: "Copilot slow\tt1"), actual: incident);
    }

    [Fact]
    public static void NoIncidentOnAUsedComponentIsNone()
    {
        GitHubIncident incident = Evaluate(
            """{"incidents":[{"name":"Copilot slow","impact":"major","created_at":"t1","components":[{"name":"Copilot"}]}]}"""
        );

        Assert.Equal(expected: new(Kind: GitHubIncidentKind.NONE, Line: string.Empty), actual: incident);
    }

    [Theory]
    [InlineData("")]
    [InlineData("<html/>")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("""{"incidents":{}}""")]
    [InlineData("""{"page":{}}""")]
    public static void AStatusThatIsNotTheExpectedJsonFails(string json)
    {
        Assert.Throws<JqException>(() => Evaluate(json));
    }

    [Fact]
    public static void TheDefaultRulesAreLibGlobalsLists()
    {
        Assert.Equal(
            expected: ["Git Operations", "Pull Requests", "Issues", "API Requests", "Webhooks", "Actions"],
            actual: GitHubHealthRules.Default.Components
        );
        Assert.Equal(expected: ["major", "critical"], actual: GitHubHealthRules.Default.SeriousImpacts);
        Assert.Equal(expected: ["partial_outage", "major_outage"], actual: GitHubHealthRules.Default.OutageStatuses);
    }

    private static GitHubIncident Evaluate(string json)
    {
        return GitHubIncidentEvaluator.Evaluate(json: json, rules: GitHubHealthRules.Default);
    }
}
