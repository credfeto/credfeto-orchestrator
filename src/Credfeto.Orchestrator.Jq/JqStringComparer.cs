using System.Collections.Generic;
using System.Text;

namespace Credfeto.Orchestrator.Jq;

// jq compares strings by their UTF-8 bytes, which is code point order (not UTF-16 ordinal order)
public sealed class JqStringComparer : IComparer<string>
{
    public static readonly JqStringComparer Instance = new();

    private JqStringComparer() { }

    public int Compare(string? x, string? y)
    {
        using IEnumerator<Rune> left = (x ?? string.Empty).EnumerateRunes().GetEnumerator();
        using IEnumerator<Rune> right = (y ?? string.Empty).EnumerateRunes().GetEnumerator();

        while (true)
        {
            bool hasLeft = left.MoveNext();
            bool hasRight = right.MoveNext();

            if (!hasLeft || !hasRight)
            {
                return hasLeft.CompareTo(hasRight);
            }

            int compared = left.Current.Value.CompareTo(right.Current.Value);

            if (compared != 0)
            {
                return compared;
            }
        }
    }
}
