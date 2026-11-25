using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

public interface ISshAgentKeyState
{
    ValueTask<SshKeyState> KeyStateAsync(string socket, CancellationToken cancellationToken);
}
