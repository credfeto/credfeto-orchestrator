using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

public interface IUrlReader
{
    // Returns the body, as curl --silent --fail prints it; throws UrlReadException when curl would fail
    ValueTask<string> ReadAsync(UrlRequest request, CancellationToken cancellationToken);
}
