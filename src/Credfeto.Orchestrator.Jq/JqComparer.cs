using System;
using System.Collections.Generic;
using System.Linq;

namespace Credfeto.Orchestrator.Jq;

// jq's total order: by kind first, then numbers numerically, strings by UTF-8 bytes (code point
// order), arrays element by element, and objects by their sorted key sets and then their values.
public sealed class JqComparer : IComparer<JqValue>
{
    public static readonly JqComparer Instance = new();

    private JqComparer() { }

    public int Compare(JqValue? x, JqValue? y)
    {
        if (x is null)
        {
            return y is null ? 0 : -1;
        }

        if (y is null)
        {
            return 1;
        }

        int kind = x.Kind.CompareTo(y.Kind);

        if (kind != 0)
        {
            return kind;
        }

        return x.Kind switch
        {
            JqKind.NUMBER => x.Number.CompareTo(y.Number),
            JqKind.TEXT => JqStringComparer.Instance.Compare(x: x.Text, y: y.Text),
            JqKind.ARRAY => this.CompareArrays(x: x.Items, y: y.Items),
            JqKind.DICTIONARY => this.CompareObjects(x: x, y: y),
            _ => 0,
        };
    }

    private int CompareArrays(IReadOnlyList<JqValue> x, IReadOnlyList<JqValue> y)
    {
        int shared = Math.Min(val1: x.Count, val2: y.Count);

        for (int index = 0; index < shared; index++)
        {
            int compared = this.Compare(x: x[index], y: y[index]);

            if (compared != 0)
            {
                return compared;
            }
        }

        return x.Count.CompareTo(y.Count);
    }

    private int CompareObjects(JqValue x, JqValue y)
    {
        IReadOnlyList<JqProperty> left = SortedProperties(x);
        IReadOnlyList<JqProperty> right = SortedProperties(y);

        int keys = this.CompareArrays(
            x: [.. left.Select(static property => JqValue.FromString(property.Name))],
            y: [.. right.Select(static property => JqValue.FromString(property.Name))]
        );

        if (keys != 0)
        {
            return keys;
        }

        for (int index = 0; index < left.Count; index++)
        {
            int compared = this.Compare(x: left[index].Value, y: right[index].Value);

            if (compared != 0)
            {
                return compared;
            }
        }

        return 0;
    }

    private static IReadOnlyList<JqProperty> SortedProperties(JqValue value)
    {
        return
        [
            .. value.Properties.OrderBy(
                keySelector: static property => property.Name,
                comparer: JqStringComparer.Instance
            ),
        ];
    }
}
