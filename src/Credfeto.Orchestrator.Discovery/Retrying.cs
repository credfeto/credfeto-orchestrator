using System;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Discovery;

internal static class Retrying
{
    // Runs attempt until it succeeds or policy.Attempts have failed with TException; the last failure propagates
    public static async ValueTask<T> RunAsync<T, TException>(
        Func<CancellationToken, ValueTask<T>> attempt,
        RetryPolicy policy,
        IRetryDelay delay,
        CancellationToken cancellationToken
    )
        where TException : Exception
    {
        for (int number = 1; number < policy.Attempts; number++)
        {
            try
            {
                return await attempt(cancellationToken);
            }
            catch (TException)
            {
                if (policy.Delay > TimeSpan.Zero)
                {
                    await delay.DelayAsync(delay: policy.Delay, cancellationToken: cancellationToken);
                }
            }
        }

        return await attempt(cancellationToken);
    }
}
