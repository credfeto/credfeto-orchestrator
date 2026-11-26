using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Podman;

// One search of an EreProgram over a text: a new thread is started at each position until a match is found; each
// state holds the earliest start that reached it at the current position. A match is kept when it starts earlier
// than the one found so far, or at the same start and ends later; once one is found, threads that started after it
// are dropped and the search ends when no thread is left.
internal sealed class EreRun
{
    private readonly IReadOnlyList<EreState> _states;
    private readonly int _entry;
    private readonly int _textLength;
    private readonly Stack<int> _pending = new();
    private EreThreadList _current;
    private EreThreadList _next;
    private int _matchStart = -1;
    private int _matchEnd = -1;

    public EreRun(EreProgram program, int textLength)
    {
        this._states = program.States;
        this._entry = program.Entry;
        this._textLength = textLength;
        this._current = new(program.States.Count);
        this._next = new(program.States.Count);
    }

    private bool Found => this._matchStart >= 0;

    public (int Start, int Length)? Find(ReadOnlySpan<byte> text, bool firstOnly)
    {
        int position = 0;

        while (true)
        {
            if (!this.Found)
            {
                this.AddThread(list: this._current, state: this._entry, start: position, position: position);
            }

            if (firstOnly && this.Found || position == text.Length)
            {
                break;
            }

            this.Step(value: text[position], position: position);
            position++;

            if (this.Found && this._current.Count == 0)
            {
                break;
            }
        }

        return this.Found ? (this._matchStart, this._matchEnd - this._matchStart) : null;
    }

    private void Step(byte value, int position)
    {
        this._next.Clear();

        for (int index = 0; index < this._current.Count; index++)
        {
            int state = this._current.StateAt(index);
            int start = this._current.StartOf(state);

            if (this.Found && start > this._matchStart)
            {
                continue;
            }

            EreState current = this._states[state];

            if (current.Characters!.Matches(value))
            {
                this.AddThread(list: this._next, state: current.Next, start: start, position: position + 1);
            }
        }

        (this._current, this._next) = (this._next, this._current);
    }

    // Follows the states reachable from state without consuming a byte, giving each the start unless it already
    // holds an earlier one, and records a match reached on the way
    private void AddThread(EreThreadList list, int state, int start, int position)
    {
        this._pending.Push(state);

        while (this._pending.TryPop(out int reached))
        {
            if (
                !list.Offer(
                    state: reached,
                    start: start,
                    keep: this._states[reached].Operation == EreOperation.CHARACTER
                )
            )
            {
                continue;
            }

            this.Follow(state: this._states[reached], start: start, position: position);
        }
    }

    private void Follow(EreState state, int start, int position)
    {
        switch (state.Operation)
        {
            case EreOperation.SPLIT:
                this._pending.Push(state.Alternative);
                this._pending.Push(state.Next);

                break;
            case EreOperation.BEGIN when position == 0:
            case EreOperation.END when position == this._textLength:
                this._pending.Push(state.Next);

                break;
            case EreOperation.MATCH:
                this.Record(start: start, end: position);

                break;
            default:
                break;
        }
    }

    private void Record(int start, int end)
    {
        if (!this.Found || start < this._matchStart || start == this._matchStart && end > this._matchEnd)
        {
            this._matchStart = start;
            this._matchEnd = end;
        }
    }
}
