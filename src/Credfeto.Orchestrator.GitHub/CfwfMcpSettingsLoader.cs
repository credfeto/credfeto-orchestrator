using System;
using System.Buffers;

namespace Credfeto.Orchestrator.GitHub;

// The endpoint and the token the agent's cfwf-mcp-headers helper would send: GH_ENTERPRISE_TOKEN, then GH_TOKEN. The
// tool never runs gh, so the helper's last fallback (gh auth token) is not taken; oneshot exports both variables from
// .env (lib/core).
public static class CfwfMcpSettingsLoader
{
    public const string DefaultEndpoint = "https://workflow-mcp.markridgwell.com/mcp";

    public const string EndpointVariable = "ORCHESTRATOR_CFWF_MCP_URL";

    private static readonly string[] TokenVariables = ["GH_ENTERPRISE_TOKEN", "GH_TOKEN"];

    // RFC 6750's token68 characters, as the helper checks, so a value can never smuggle in a second header
    private static readonly SearchValues<char> TokenCharacters = SearchValues.Create(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+/=-"
    );

    public static CfwfMcpSettings Load(Func<string, string?> environment)
    {
        return new(endpoint: Endpoint(environment(EndpointVariable)), token: Token(environment));
    }

    private static Uri Endpoint(string? value)
    {
        // An empty value counts as unset, as lib/globals treats it
        string url = string.IsNullOrEmpty(value) ? DefaultEndpoint : value;

        if (
            Uri.TryCreate(uriString: url, uriKind: UriKind.Absolute, result: out Uri? endpoint)
            && StringComparer.Ordinal.Equals(x: endpoint.Scheme, y: Uri.UriSchemeHttps)
        )
        {
            return endpoint;
        }

        // The value is not echoed: it is operator configuration, but it could hold credentials
        throw new GitHubReadException($"{EndpointVariable} is not an https URL");
    }

    private static string Token(Func<string, string?> environment)
    {
        foreach (string variable in TokenVariables)
        {
            string? token = environment(variable);

            if (string.IsNullOrEmpty(token))
            {
                continue;
            }

            return token.AsSpan().ContainsAnyExcept(TokenCharacters)
                ? throw new GitHubReadException("the GitHub token holds characters a bearer token cannot contain")
                : token;
        }

        throw new GitHubReadException("no GitHub token: set GH_ENTERPRISE_TOKEN or GH_TOKEN");
    }
}
