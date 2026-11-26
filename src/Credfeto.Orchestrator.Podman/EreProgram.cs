using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Podman;

// A compiled EreParser pattern: a Thompson NFA run over the text one byte at a time. Each state keeps only the
// earliest start that reaches it, which loses nothing because the states' futures do not depend on where a thread
// started (the subset has no back-references). That gives exactly the overall match POSIX regexec reports: the
// leftmost start, then the longest match from it (glibc: "(pushed|pushed yet)" takes "pushed yet", where a
// backtracking engine takes "pushed"). Sub-match positions are not tracked; the heuristics read only the whole match.
public sealed class EreProgram
{
    // A pattern whose counted repeats expand past this many states is refused rather than run
    private const int MAXIMUM_STATES = 100_000;

    private EreProgram(IReadOnlyList<EreState> states, int entry)
    {
        this.States = states;
        this.Entry = entry;
    }

    internal IReadOnlyList<EreState> States { get; }

    internal int Entry { get; }

    public static EreProgram Compile(string pattern)
    {
        EreNode node = EreParser.Parse(pattern);
        List<EreState> states = [new EreState(EreOperation.MATCH)];
        int entry = CompileNode(node: node, next: 0, states: states);

        return new(states: states, entry: entry);
    }

    public bool IsMatch(ReadOnlySpan<byte> text)
    {
        return new EreRun(program: this, textLength: text.Length).Find(text: text, firstOnly: true) is not null;
    }

    // The leftmost-longest match as (start, length), or null when there is none
    public (int Start, int Length)? FindLeftmostLongest(ReadOnlySpan<byte> text)
    {
        return new EreRun(program: this, textLength: text.Length).Find(text: text, firstOnly: false);
    }

    // Compiles node so that it continues at state next, and returns the state it starts at
    private static int CompileNode(EreNode node, int next, List<EreState> states)
    {
        if (states.Count > MAXIMUM_STATES)
        {
            throw new PodmanRefusedException("a pattern's repeats expand to too many states to run");
        }

        return node.Kind switch
        {
            EreNodeKind.ATOM => Add(states: states, state: new(EreOperation.CHARACTER, node.Characters, next)),
            EreNodeKind.ANCHOR => Add(
                states: states,
                state: new(node.Begin ? EreOperation.BEGIN : EreOperation.END, null, next)
            ),
            EreNodeKind.SEQUENCE => CompileSequence(items: node.Items, next: next, states: states),
            EreNodeKind.ALTERNATION => CompileAlternation(branches: node.Items, next: next, states: states),
            EreNodeKind.REPEAT => CompileRepeat(repeat: node, next: next, states: states),
            _ => throw new PodmanRefusedException("a pattern holds a construct the matcher does not know"),
        };
    }

    private static int CompileSequence(IReadOnlyList<EreNode> items, int next, List<EreState> states)
    {
        int entry = next;

        for (int index = items.Count - 1; index >= 0; index--)
        {
            entry = CompileNode(node: items[index], next: entry, states: states);
        }

        return entry;
    }

    private static int CompileAlternation(IReadOnlyList<EreNode> branches, int next, List<EreState> states)
    {
        int entry = CompileNode(node: branches[^1], next: next, states: states);

        for (int index = branches.Count - 2; index >= 0; index--)
        {
            int branch = CompileNode(node: branches[index], next: next, states: states);
            entry = Add(states: states, state: new(EreOperation.SPLIT, null, branch, entry));
        }

        return entry;
    }

    // item{m,n} is m copies of item followed by n - m optional copies; item{m,} is m copies followed by item*
    private static int CompileRepeat(EreNode repeat, int next, List<EreState> states)
    {
        int entry;

        if (repeat.Maximum == EreNode.Unbounded)
        {
            entry = Add(states: states, state: new(EreOperation.SPLIT, null, next, next));
            int body = CompileNode(node: repeat.Items[0], next: entry, states: states);
            states[entry] = new(EreOperation.SPLIT, null, body, next);
        }
        else
        {
            entry = next;

            for (int optional = repeat.Minimum; optional < repeat.Maximum; optional++)
            {
                int body = CompileNode(node: repeat.Items[0], next: entry, states: states);
                entry = Add(states: states, state: new(EreOperation.SPLIT, null, body, entry));
            }
        }

        for (int copy = 0; copy < repeat.Minimum; copy++)
        {
            entry = CompileNode(node: repeat.Items[0], next: entry, states: states);
        }

        return entry;
    }

    private static int Add(List<EreState> states, EreState state)
    {
        states.Add(state);

        return states.Count - 1;
    }
}
