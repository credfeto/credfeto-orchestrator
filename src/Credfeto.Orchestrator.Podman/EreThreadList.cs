namespace Credfeto.Orchestrator.Podman;

// The states reached at one position, each with the earliest start that reached it; the CHARACTER states, which the
// next byte steps, are also kept in a list in the order they were first reached
internal sealed class EreThreadList
{
    private readonly int[] _starts;
    private readonly int[] _stamps;
    private readonly int[] _characterStates;
    private int _generation = 1;

    public EreThreadList(int stateCount)
    {
        this._starts = new int[stateCount];
        this._stamps = new int[stateCount];
        this._characterStates = new int[stateCount];
    }

    public int Count { get; private set; }

    public void Clear()
    {
        this._generation++;
        this.Count = 0;
    }

    public int StateAt(int index)
    {
        return this._characterStates[index];
    }

    public int StartOf(int state)
    {
        return this._starts[state];
    }

    // Gives state the start; false when it already holds that start or an earlier one, so there is nothing new to follow
    public bool Offer(int state, int start, bool keep)
    {
        if (this._stamps[state] == this._generation)
        {
            if (this._starts[state] <= start)
            {
                return false;
            }

            this._starts[state] = start;

            return true;
        }

        this._stamps[state] = this._generation;
        this._starts[state] = start;

        if (keep)
        {
            this._characterStates[this.Count++] = state;
        }

        return true;
    }
}
