using System;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class RetryDelayTests : TestBase
{
    [Fact]
    public async Task AShortDelayCompletesAsync()
    {
        await new RetryDelay().DelayAsync(
            delay: TimeSpan.FromMilliseconds(1),
            cancellationToken: this.CancellationToken()
        );
    }

    [Fact]
    public async Task ACancelledDelayStopsAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new RetryDelay().DelayAsync(delay: TimeSpan.FromHours(1), cancellationToken: cancelled.Token).AsTask()
        );
    }
}
