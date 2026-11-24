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
}
