using System;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

// The sleep between two attempts of a retried read
public interface IRetryDelay
{
    ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken);
}
