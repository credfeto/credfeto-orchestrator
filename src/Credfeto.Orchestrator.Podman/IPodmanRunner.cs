using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman;

public interface IPodmanRunner
{
    // Runs podman <arguments> and returns its stdout and exit status; podman's stderr is not captured
    ValueTask<PodmanResult> RunAsync(IReadOnlyList<string> arguments, CancellationToken cancellationToken);
}
