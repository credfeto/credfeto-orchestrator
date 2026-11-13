using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Commands;

public sealed class FileContentReader : IFileContentReader
{
    public async ValueTask<string> ReadAllTextAsync(string path, CancellationToken cancellationToken)
    {
        return await File.ReadAllTextAsync(path: path, cancellationToken: cancellationToken);
    }
}
