using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents.Tests;

// Records each stop asked for as "socket user", then throws Failure when there is one
internal sealed class FakeSshAgentStopper : ISshAgentStopper
{
    public Exception? Failure { get; init; }

    public List<string> Asked { get; } = [];

    public ValueTask StopAsync(string socket, string user, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        this.Asked.Add(socket + " " + user);

        return this.Failure is null ? ValueTask.CompletedTask : ValueTask.FromException(this.Failure);
    }
}
