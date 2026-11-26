using System;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Install.Tests;

// A check that counts its runs and throws the exception it was given, if any
internal sealed class FakeSelfTestCheck : ISelfTestCheck
{
    private readonly Exception? _failure;

    public FakeSelfTestCheck(string name, Exception? failure = null)
    {
        this.Name = name;
        this._failure = failure;
    }

    public int Runs { get; private set; }

    public string Name { get; }

    public ValueTask RunAsync(CancellationToken cancellationToken)
    {
        this.Runs++;

        return this._failure is null ? ValueTask.CompletedTask : ValueTask.FromException(this._failure);
    }
}
