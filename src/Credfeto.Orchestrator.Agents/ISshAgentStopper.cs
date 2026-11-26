using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

public interface ISshAgentStopper
{
    // Sends SIGTERM to every process pkill -u <user> -f "ssh-agent -a <socket>" would signal, or throws
    // AgentRefusedException, having signalled nothing, when it cannot tell exactly which those are
    ValueTask StopAsync(string socket, string user, CancellationToken cancellationToken);
}
