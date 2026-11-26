using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman;

// One NFA state: CHARACTER consumes a byte Characters matches and goes to Next; BEGIN and END go to Next at the start
// or the end of the text; SPLIT goes to both Next and Alternative; MATCH ends a match
[DebuggerDisplay("Operation={Operation}, Next={Next}, Alternative={Alternative}")]
internal sealed class EreState
{
    public EreState(EreOperation operation, EreCharClass? characters = null, int next = 0, int alternative = 0)
    {
        this.Operation = operation;
        this.Characters = characters;
        this.Next = next;
        this.Alternative = alternative;
    }

    public EreOperation Operation { get; }

    public EreCharClass? Characters { get; }

    public int Next { get; }

    public int Alternative { get; }
}
