using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

public interface IUserDirectory
{
    // The uid of the named user, or null when the name is not there to look up
    ValueTask<uint?> UidAsync(string name, CancellationToken cancellationToken);
}
