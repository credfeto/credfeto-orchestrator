using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.GitHub;

public interface IMcpToolCaller
{
    // Returns the tool's JSON result text; throws GitHubReadException when the call or the tool fails
    ValueTask<string> CallAsync(
        string tool,
        IReadOnlyDictionary<string, string> arguments,
        CancellationToken cancellationToken
    );
}
