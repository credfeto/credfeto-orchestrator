using System;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

public sealed class RetryDelay : IRetryDelay
{
    public async ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        await Task.Delay(delay: delay, cancellationToken: cancellationToken);
    }
}
