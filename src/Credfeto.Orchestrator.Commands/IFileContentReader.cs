using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Commands;

public interface IFileContentReader
{
    ValueTask<string> ReadAllTextAsync(string path, CancellationToken cancellationToken);
}
