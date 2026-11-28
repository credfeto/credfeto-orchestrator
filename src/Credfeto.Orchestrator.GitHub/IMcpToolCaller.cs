using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.GitHub;

public interface IMcpToolCaller
{
    // Each argument is the JSON value the tool takes (see McpArgument); returns the tool's JSON result text and throws
    // GitHubReadException when the call or the tool fails
    ValueTask<string> CallAsync(
        string tool,
        IReadOnlyDictionary<string, JsonElement> arguments,
        CancellationToken cancellationToken
    );

    // The names of the tools the server lists (tools/list); throws GitHubReadException when they cannot be read
    ValueTask<IReadOnlyList<string>> ListToolsAsync(CancellationToken cancellationToken);
}
