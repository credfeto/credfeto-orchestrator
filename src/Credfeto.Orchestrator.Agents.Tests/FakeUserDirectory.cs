using System;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents.Tests;

// Knows one user name, with its uid
internal sealed class FakeUserDirectory : IUserDirectory
{
    private readonly string _name;
    private readonly uint _uid;

    public FakeUserDirectory(string name, uint uid)
    {
        this._name = name;
        this._uid = uid;
    }

    public ValueTask<uint?> UidAsync(string name, CancellationToken cancellationToken)
    {
        return ValueTask.FromResult<uint?>(StringComparer.Ordinal.Equals(x: name, y: this._name) ? this._uid : null);
    }
}
