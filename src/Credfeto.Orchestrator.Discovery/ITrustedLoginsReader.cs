using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

public interface ITrustedLoginsReader
{
    // get_trusted_logins: the JSON array of trusted logins, reading the collaborators through the cfwf MCP server and
    // retrying a failed read as retry says. Throws GitHubReadException when every attempt fails, so the caller skips
    // the item rather than trusting a shrunken list
    ValueTask<string> ReadAsync(TrustedLoginsRequest request, RetryPolicy retry, CancellationToken cancellationToken);
}
