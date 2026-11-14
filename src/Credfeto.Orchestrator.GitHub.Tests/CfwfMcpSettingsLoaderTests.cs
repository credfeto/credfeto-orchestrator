using System;
using System.Collections.Generic;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

public sealed class CfwfMcpSettingsLoaderTests : TestBase
{
    private const string TOKEN = "ghp_Abc123._~+/=-";

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public static void TheDefaultEndpointIsUsedWhenUnsetOrEmpty(string? endpoint)
    {
        CfwfMcpSettings settings = Load(("ORCHESTRATOR_CFWF_MCP_URL", endpoint), ("GH_TOKEN", TOKEN));

        Assert.Equal(expected: new Uri("https://workflow-mcp.markridgwell.com/mcp"), actual: settings.Endpoint);
        Assert.Equal(expected: TOKEN, actual: settings.Token);
    }

    [Fact]
    public static void AnHttpsEndpointOverridesTheDefault()
    {
        CfwfMcpSettings settings = Load(
            ("ORCHESTRATOR_CFWF_MCP_URL", "https://mcp.example.test/cfwf/mcp"),
            ("GH_TOKEN", TOKEN)
        );

        Assert.Equal(expected: new Uri("https://mcp.example.test/cfwf/mcp"), actual: settings.Endpoint);
    }

    [Theory]
    [InlineData("http://mcp.example.test/mcp")]
    [InlineData("mcp.example.test/mcp")]
    [InlineData("not a url")]
    public static void AnEndpointThatIsNotHttpsIsRefused(string endpoint)
    {
        GitHubReadException exception = Assert.Throws<GitHubReadException>(() =>
            Load(("ORCHESTRATOR_CFWF_MCP_URL", endpoint), ("GH_TOKEN", TOKEN))
        );

        Assert.Equal(expected: "ORCHESTRATOR_CFWF_MCP_URL is not an https URL", actual: exception.Message);
    }

    [Fact]
    public static void TheEnterpriseTokenIsPreferred()
    {
        CfwfMcpSettings settings = Load(("GH_ENTERPRISE_TOKEN", "enterprise"), ("GH_TOKEN", TOKEN));

        Assert.Equal(expected: "enterprise", actual: settings.Token);
    }

    [Fact]
    public static void AnEmptyEnterpriseTokenFallsBackToGhToken()
    {
        CfwfMcpSettings settings = Load(("GH_ENTERPRISE_TOKEN", ""), ("GH_TOKEN", TOKEN));

        Assert.Equal(expected: TOKEN, actual: settings.Token);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public static void NoTokenIsAFailedRead(string? token)
    {
        GitHubReadException exception = Assert.Throws<GitHubReadException>(() =>
            Load(("GH_ENTERPRISE_TOKEN", token), ("GH_TOKEN", token))
        );

        Assert.Equal(expected: "no GitHub token: set GH_ENTERPRISE_TOKEN or GH_TOKEN", actual: exception.Message);
    }

    [Theory]
    [InlineData("tok\nX-Injected: yes")]
    [InlineData("tok en")]
    [InlineData("tok\u00e9")]
    public static void ATokenWithCharactersABearerTokenCannotHoldIsRefusedWithoutEchoingIt(string token)
    {
        GitHubReadException exception = Assert.Throws<GitHubReadException>(() => Load(("GH_TOKEN", token)));

        Assert.Equal(
            expected: "the GitHub token holds characters a bearer token cannot contain",
            actual: exception.Message
        );
    }

    private static CfwfMcpSettings Load(params (string Name, string? Value)[] variables)
    {
        Dictionary<string, string?> environment = [with(StringComparer.Ordinal)];

        foreach ((string name, string? value) in variables)
        {
            environment[name] = value;
        }

        return CfwfMcpSettingsLoader.Load(name => environment.GetValueOrDefault(name));
    }
}
