using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

public sealed class McpToolCallerTests : TestBase
{
    private const string TOKEN = "tok-123";

    private static readonly Dictionary<string, string> PrListArguments = new(StringComparer.Ordinal)
    {
        ["repo"] = "org/repo",
        ["head"] = "fix/7-typo",
    };

    [Fact]
    public async Task TheToolsTextResultIsReturnedWithTheBearerTokenOnEveryRequestAsync()
    {
        using FakeMcpServerHandler server = new(id => Result(id: id, content: TextContent("{\"pullRequests\":[]}")));

        string text = await CallAsync(server: server, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: "{\"pullRequests\":[]}", actual: text);
        Assert.NotEmpty(server.Requests);
        Assert.All(
            server.Requests,
            request => Assert.Equal(expected: "Bearer " + TOKEN, actual: request.Authorization)
        );
        AssertToolCall(server);
    }

    [Fact]
    public async Task AToolErrorIsAFailedReadWithTheServersMessageAsync()
    {
        using FakeMcpServerHandler server = new(id =>
            Result(
                id: id,
                content: TextContent("the repository org/repo was not found, or the caller cannot see it"),
                isError: true
            )
        );

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            CallAsync(server: server, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(
            expected: "the cfwf MCP server's pr_list failed: "
                + "the repository org/repo was not found, or the caller cannot see it",
            actual: exception.Message
        );
    }

    [Fact]
    public async Task AToolErrorWithoutTextIsAFailedReadAsync()
    {
        using FakeMcpServerHandler server = new(id => Result(id: id, content: string.Empty, isError: true));

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            CallAsync(server: server, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(expected: "the cfwf MCP server's pr_list failed: no message", actual: exception.Message);
    }

    [Fact]
    public async Task AResultWithoutTextIsAFailedReadAsync()
    {
        using FakeMcpServerHandler server = new(id => Result(id: id, content: string.Empty));

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            CallAsync(server: server, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(expected: "the cfwf MCP server's pr_list returned no text result", actual: exception.Message);
    }

    [Fact]
    public async Task AProtocolErrorIsAFailedReadAsync()
    {
        using FakeMcpServerHandler server = new(id =>
            "{\"jsonrpc\":\"2.0\",\"id\":"
            + id
            + ",\"error\":{\"code\":-32602,\"message\":\"Unknown tool: 'pr_list'\"}}"
        );

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            CallAsync(server: server, cancellationToken: this.CancellationToken())
        );

        Assert.StartsWith(
            expectedStartString: "the cfwf MCP server could not be asked for pr_list: ",
            actualString: exception.Message,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.BadGateway)]
    public async Task ARefusedSessionIsAFailedReadAsync(HttpStatusCode status)
    {
        using FakeMcpServerHandler server = new(toolsCallResponse: _ => "{}", initializeStatus: status);

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            CallAsync(server: server, cancellationToken: this.CancellationToken())
        );

        Assert.StartsWith(
            expectedStartString: "the cfwf MCP server could not be asked for pr_list: ",
            actualString: exception.Message,
            comparisonType: StringComparison.Ordinal
        );
        Assert.DoesNotContain(
            expectedSubstring: TOKEN,
            actualString: exception.Message,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task AnHttpTimeoutIsAFailedReadAsync()
    {
        using FakeMcpServerHandler server = new(static _ => throw new TaskCanceledException("timed out"));

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            CallAsync(server: server, cancellationToken: this.CancellationToken())
        );

        Assert.StartsWith(
            expectedStartString: "the cfwf MCP server could not be asked for pr_list: ",
            actualString: exception.Message,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task AnUnexpectedFailureIsNotTurnedIntoAFailedReadAsync()
    {
        using FakeMcpServerHandler server = new(static _ => throw new InvalidOperationException("a bug"));

        Exception? exception = await Record.ExceptionAsync(async () =>
            _ = await CallAsync(server: server, cancellationToken: this.CancellationToken())
        );

        Assert.IsNotType<GitHubReadException>(exception);
        Assert.NotNull(exception);
    }

    [Fact]
    public async Task SettingsThatCannotBeLoadedAreAFailedReadBeforeAnyRequestAsync()
    {
        using FakeMcpServerHandler server = new(id => Result(id: id, content: TextContent("{}")));
        using HttpClient httpClient = new(handler: server, disposeHandler: false);
        McpToolCaller caller = new(
            httpClient: httpClient,
            settings: static () => throw new GitHubReadException("no GitHub token: set GH_ENTERPRISE_TOKEN or GH_TOKEN")
        );

        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            caller
                .CallAsync(tool: "pr_list", arguments: PrListArguments, cancellationToken: this.CancellationToken())
                .AsTask()
        );

        Assert.Equal(expected: "no GitHub token: set GH_ENTERPRISE_TOKEN or GH_TOKEN", actual: exception.Message);
        Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task ACancelledCallIsNotAFailedReadAsync()
    {
        using FakeMcpServerHandler server = new(id => Result(id: id, content: TextContent("{}")));
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CallAsync(server: server, cancellationToken: cancelled.Token)
        );
    }

    private static async Task<string> CallAsync(FakeMcpServerHandler server, CancellationToken cancellationToken)
    {
        using HttpClient httpClient = new(handler: server, disposeHandler: false);
        McpToolCaller caller = new(
            httpClient: httpClient,
            settings: static () => new(endpoint: new("https://mcp.example.test/mcp"), token: TOKEN)
        );

        return await caller.CallAsync(
            tool: "pr_list",
            arguments: PrListArguments,
            cancellationToken: cancellationToken
        );
    }

    private static void AssertToolCall(FakeMcpServerHandler server)
    {
        RecordedRequest call = Assert.Single(
            server.Requests,
            request => request.Body.Contains(value: "\"tools/call\"", comparisonType: StringComparison.Ordinal)
        );
        using JsonDocument body = JsonDocument.Parse(call.Body);
        JsonElement parameters = body.RootElement.GetProperty("params");

        Assert.Equal(expected: "pr_list", actual: parameters.GetProperty("name").GetString());
        Assert.Equal(
            expected: ["head=fix/7-typo", "repo=org/repo"],
            actual: parameters
                .GetProperty("arguments")
                .EnumerateObject()
                .Select(argument => argument.Name + "=" + argument.Value.GetString())
                .Order(StringComparer.Ordinal),
            comparer: StringComparer.Ordinal
        );
    }

    private static string TextContent(string text)
    {
        return "{\"type\":\"text\",\"text\":"
            + JsonSerializer.Serialize(value: text, jsonTypeInfo: TestJsonContext.Default.String)
            + "}";
    }

    private static string Result(string id, string content, bool isError = false)
    {
        return "{\"jsonrpc\":\"2.0\",\"id\":"
            + id
            + ",\"result\":{\"content\":["
            + content
            + "],\"isError\":"
            + (isError ? "true" : "false")
            + "}}";
    }
}
