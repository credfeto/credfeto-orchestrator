using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Install;

// One offline check of a part of the tool against a tiny built-in input
public interface ISelfTestCheck
{
    string Name { get; }

    // Throws SelfTestFailedException saying what differed
    ValueTask RunAsync(CancellationToken cancellationToken);
}
