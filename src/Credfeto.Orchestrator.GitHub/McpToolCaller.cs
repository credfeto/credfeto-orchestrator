using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ModelContextProtocol;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

namespace Credfeto.Orchestrator.GitHub;

// One MCP session per call, over Streamable HTTP, with the Authorization header the agent's cfwf-mcp-headers helper
// sends
public sealed class McpToolCaller : IMcpToolCaller
{
    private static readonly McpClientOptions ClientOptions = new()
    {
        ClientInfo = new() { Name = "credfeto-orchestrator", Version = "1.0.0" },
    };

    private readonly HttpClient _httpClient;
    private readonly Func<CfwfMcpSettings> _settings;

    public McpToolCaller(HttpClient httpClient, Func<CfwfMcpSettings> settings)
    {
        this._httpClient = httpClient;
        this._settings = settings;
    }

    public async ValueTask<string> CallAsync(
        string tool,
        IReadOnlyDictionary<string, string> arguments,
        CancellationToken cancellationToken
    )
    {
        CfwfMcpSettings settings = this._settings();
        CallToolResult result = await this.CallToolAsync(
            settings: settings,
            tool: tool,
            arguments: arguments,
            cancellationToken: cancellationToken
        );

        return Text(tool: tool, result: result);
    }

    private async ValueTask<CallToolResult> CallToolAsync(
        CfwfMcpSettings settings,
        string tool,
        IReadOnlyDictionary<string, string> arguments,
        CancellationToken cancellationToken
    )
    {
        try
        {
            await using HttpClientTransport transport = new(
                transportOptions: TransportOptions(settings),
                httpClient: this._httpClient,
                loggerFactory: null,
                ownsHttpClient: false
            );
            await using McpClient client = await McpClient.CreateAsync(
                clientTransport: transport,
                clientOptions: ClientOptions,
                loggerFactory: null,
                cancellationToken: cancellationToken
            );

            return await client.CallToolAsync(
                requestParams: new() { Name = tool, Arguments = Arguments(arguments) },
                cancellationToken: cancellationToken
            );
        }
        catch (Exception exception) when (IsCallFailure(exception: exception, cancellationToken: cancellationToken))
        {
            throw new GitHubReadException(
                message: $"the cfwf MCP server could not be asked for {tool}: {exception.Message}",
                innerException: exception
            );
        }
    }

    // A cancelled run is left to propagate; an HTTP timeout is a failed read
    private static bool IsCallFailure(Exception exception, CancellationToken cancellationToken)
    {
        return exception switch
        {
            OperationCanceledException => !cancellationToken.IsCancellationRequested,
            McpException or HttpRequestException or IOException or JsonException or TimeoutException => true,
            _ => false,
        };
    }

    private static HttpClientTransportOptions TransportOptions(CfwfMcpSettings settings)
    {
        return new()
        {
            Endpoint = settings.Endpoint,
            Name = "cfwf",
            TransportMode = HttpTransportMode.StreamableHttp,
            AdditionalHeaders = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["Authorization"] = "Bearer " + settings.Token,
            },
        };
    }

    private static Dictionary<string, JsonElement> Arguments(IReadOnlyDictionary<string, string> arguments)
    {
        return arguments.ToDictionary(
            keySelector: argument => argument.Key,
            elementSelector: argument =>
                JsonSerializer.SerializeToElement(
                    value: argument.Value,
                    jsonTypeInfo: GitHubJsonContext.Default.String
                ),
            comparer: StringComparer.Ordinal
        );
    }

    // The server's tool errors are fixed text that never echoes upstream detail, so the message is passed on
    private static string Text(string tool, CallToolResult result)
    {
        string? text = result.Content.OfType<TextContentBlock>().Select(block => block.Text).FirstOrDefault();

        if (result.IsError == true)
        {
            throw new GitHubReadException($"the cfwf MCP server's {tool} failed: {text ?? "no message"}");
        }

        return text ?? throw new GitHubReadException($"the cfwf MCP server's {tool} returned no text result");
    }
}
