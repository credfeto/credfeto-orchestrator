using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Discovery;

namespace Credfeto.Orchestrator.Commands.Tests;

// Records each delay instead of sleeping
internal sealed class FakeRetryDelay : IRetryDelay
{
    private readonly List<TimeSpan> _delays = [];

    public IReadOnlyList<TimeSpan> Delays => this._delays;

    public ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        this._delays.Add(delay);

        return ValueTask.CompletedTask;
    }
}
