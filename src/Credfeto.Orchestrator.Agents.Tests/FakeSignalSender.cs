using System.Collections.Generic;

namespace Credfeto.Orchestrator.Agents.Tests;

// Records the pids it was asked to terminate
internal sealed class FakeSignalSender : ISignalSender
{
    public List<int> Terminated { get; } = [];

    public void Terminate(int pid)
    {
        this.Terminated.Add(pid);
    }
}
