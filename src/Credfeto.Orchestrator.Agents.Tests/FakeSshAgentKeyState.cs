using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents.Tests;

// Answers every query with State, or throws Failure, and records the sockets asked about
internal sealed class FakeSshAgentKeyState : ISshAgentKeyState
{
    public SshKeyState State { get; init; }

    public Exception? Failure { get; init; }

    public List<string> Asked { get; } = [];

    public ValueTask<SshKeyState> KeyStateAsync(string socket, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        this.Asked.Add(socket);

        return this.Failure is null
            ? ValueTask.FromResult(this.State)
            : ValueTask.FromException<SshKeyState>(this.Failure);
    }
}
