using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman;

// A parsed POSIX extended regular expression, in the subset EreParser accepts: an ATOM (one character: a literal, "."
// or a bracket list), an ANCHOR (^ when Begin, else $: with no REG_NEWLINE only the start or the end of the whole
// text), a SEQUENCE or ALTERNATION of Items, or a REPEAT of Items[0] from Minimum to Maximum times (Unbounded for *,
// + and {m,})
[DebuggerDisplay("Kind={Kind}, Items={Items.Count}")]
internal sealed class EreNode
{
    public const int Unbounded = -1;

    private EreNode(
        EreNodeKind kind,
        EreCharClass? characters,
        bool begin,
        IReadOnlyList<EreNode> items,
        int minimum,
        int maximum
    )
    {
        this.Kind = kind;
        this.Characters = characters;
        this.Begin = begin;
        this.Items = items;
        this.Minimum = minimum;
        this.Maximum = maximum;
    }

    public EreNodeKind Kind { get; }

    public EreCharClass? Characters { get; }

    public bool Begin { get; }

    public IReadOnlyList<EreNode> Items { get; }

    public int Minimum { get; }

    public int Maximum { get; }

    public static EreNode Atom(EreCharClass characters)
    {
        return new(kind: EreNodeKind.ATOM, characters: characters, begin: false, items: [], minimum: 1, maximum: 1);
    }

    public static EreNode Anchor(bool begin)
    {
        return new(kind: EreNodeKind.ANCHOR, characters: null, begin: begin, items: [], minimum: 1, maximum: 1);
    }

    public static EreNode Sequence(IReadOnlyList<EreNode> items)
    {
        return new(kind: EreNodeKind.SEQUENCE, characters: null, begin: false, items: items, minimum: 1, maximum: 1);
    }

    public static EreNode Alternation(IReadOnlyList<EreNode> branches)
    {
        return new(
            kind: EreNodeKind.ALTERNATION,
            characters: null,
            begin: false,
            items: branches,
            minimum: 1,
            maximum: 1
        );
    }

    public static EreNode Repeat(EreNode item, int minimum, int maximum)
    {
        return new(
            kind: EreNodeKind.REPEAT,
            characters: null,
            begin: false,
            items: [item],
            minimum: minimum,
            maximum: maximum
        );
    }
}
