using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman;

// The reads of the permission denials in a Claude JSON result: each result is what the shell function's jq program
// prints, with status 0, as the tool answers only where jq would succeed
public interface IClaudeResultQueries
{
    // claude_result_permission_denials_summary
    ValueTask<PodmanResult> DenialsSummaryAsync(string resultFile, CancellationToken cancellationToken);

    // claude_result_denied_command_names
    ValueTask<PodmanResult> DeniedCommandNamesAsync(string resultFile, CancellationToken cancellationToken);
}
