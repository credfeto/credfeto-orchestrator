using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

public interface IProcessTable
{
    // Every process that can be read, this one included; a process that ends while it is read is left out
    ValueTask<IReadOnlyList<ProcessEntry>> ProcessesAsync(CancellationToken cancellationToken);
}
