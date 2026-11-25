using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Git;

public interface IGitRunner
{
    // Runs git -C <repository> <arguments> and returns its stdout and exit status; git's stderr is not captured
    ValueTask<GitResult> RunAsync(
        string repository,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken
    );
}
