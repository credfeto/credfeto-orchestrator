using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.GitHub.Tests;

// A minimal Streamable HTTP MCP server: it answers initialize (or refuses it with a status), accepts notifications and
// the session delete, answers tools/call with the JSON-RPC response built from the request id and, when given tools,
// tools/list with them, refuses every other method, and records every request
internal sealed class FakeMcpServerHandler : HttpMessageHandler
{
    private const string SESSION_ID = "fake-session";

    private readonly HttpStatusCode? _initializeStatus;
    private readonly List<RecordedRequest> _requests = [];
    private readonly IReadOnlyList<string>? _tools;
    private readonly Func<string, string> _toolsCallResponse;

    public FakeMcpServerHandler(
        Func<string, string> toolsCallResponse,
        HttpStatusCode? initializeStatus = null,
        IReadOnlyList<string>? tools = null
    )
    {
        this._toolsCallResponse = toolsCallResponse;
        this._initializeStatus = initializeStatus;
        this._tools = tools;
    }

    public IReadOnlyList<RecordedRequest> Requests => this._requests;

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken
    )
    {
        string body = request.Content is null
            ? string.Empty
            : await request.Content.ReadAsStringAsync(cancellationToken);
        this._requests.Add(
            new(Method: request.Method, Authorization: request.Headers.Authorization?.ToString(), Body: body)
        );

        if (request.Method == HttpMethod.Delete)
        {
            return new(HttpStatusCode.OK);
        }

        if (request.Method != HttpMethod.Post)
        {
            return new(HttpStatusCode.MethodNotAllowed);
        }

        return this.Answer(body);
    }

    private HttpResponseMessage Answer(string body)
    {
        using JsonDocument message = JsonDocument.Parse(body);
        JsonElement root = message.RootElement;

        if (!root.TryGetProperty(propertyName: "id", value: out JsonElement id))
        {
            return new(HttpStatusCode.Accepted);
        }

        string? method = root.GetProperty("method").GetString();

        if (StringComparer.Ordinal.Equals(x: method, y: "tools/call"))
        {
            return Json(this._toolsCallResponse(id.GetRawText()));
        }

        if (StringComparer.Ordinal.Equals(x: method, y: "tools/list") && this._tools is not null)
        {
            return Json(
                "{\"jsonrpc\":\"2.0\",\"id\":"
                    + id.GetRawText()
                    + ",\"result\":{\"tools\":["
                    + string.Join(
                        separator: ',',
                        values: this._tools.Select(tool =>
                            "{\"name\":\"" + tool + "\",\"inputSchema\":{\"type\":\"object\"}}"
                        )
                    )
                    + "]}}"
            );
        }

        // Any other request, such as a client's discovery probe, is one this server does not know, as an older
        // server answers it
        if (!StringComparer.Ordinal.Equals(x: method, y: "initialize"))
        {
            return Json(
                "{\"jsonrpc\":\"2.0\",\"id\":"
                    + id.GetRawText()
                    + ",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"
            );
        }

        if (this._initializeStatus is { } status)
        {
            return new(status);
        }

        string version = root.GetProperty("params").GetProperty("protocolVersion").GetString() ?? string.Empty;

        return Json(
            "{\"jsonrpc\":\"2.0\",\"id\":"
                + id.GetRawText()
                + ",\"result\":{\"protocolVersion\":\""
                + version
                + "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1.0.0\"}}}"
        );
    }

    private static HttpResponseMessage Json(string json)
    {
        HttpResponseMessage response = new(HttpStatusCode.OK)
        {
            Content = new StringContent(content: json, encoding: Encoding.UTF8, mediaType: "application/json"),
        };
        response.Headers.Add(name: "Mcp-Session-Id", value: SESSION_ID);

        return response;
    }
}
