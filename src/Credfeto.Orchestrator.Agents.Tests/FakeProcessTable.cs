using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents.Tests;

// A process table holding the processes added to it, each with its command-line text
internal sealed class FakeProcessTable : IProcessTable
{
    private readonly List<ProcessEntry> _processes = [];

    public FakeProcessTable With(int pid, uint uid, string text)
    {
        this._processes.Add(new(Pid: pid, EffectiveUid: uid, Text: Encoding.Latin1.GetBytes(text)));

        return this;
    }

    public ValueTask<IReadOnlyList<ProcessEntry>> ProcessesAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        return ValueTask.FromResult<IReadOnlyList<ProcessEntry>>(this._processes);
    }
}
