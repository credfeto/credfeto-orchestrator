using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Credfeto.Orchestrator.Jq;

// The further jq builtins the lib/github-status predicates use, with jq 1.7+ semantics, including
// where jq fails
public static class JqBuiltins
{
    // a == b (and !=): jq compares with its total order, so 1 == 1.0
    public static bool Equal(JqValue left, JqValue right)
    {
        return JqComparer.Instance.Compare(x: left, y: right) == 0;
    }

    public static bool Equal(JqValue left, string right)
    {
        return left.Kind == JqKind.TEXT && StringComparer.Ordinal.Equals(x: left.Text, y: right);
    }

    // a < b, a > b
    public static int Compare(JqValue left, JqValue right)
    {
        return JqComparer.Instance.Compare(x: left, y: right);
    }

    // .[]? : anything that cannot be iterated yields nothing
    public static IReadOnlyList<JqValue> IterateOptional(JqValue value)
    {
        return value.Kind is JqKind.ARRAY or JqKind.DICTIONARY ? JqOps.Iterate(value) : [];
    }

    // map(f)
    public static JqValue Map(JqValue value, Func<JqValue, JqValue> selector)
    {
        return JqValue.FromArray([.. JqOps.Iterate(value).Select(selector)]);
    }

    // ascii_downcase
    public static JqValue AsciiDowncase(JqValue value)
    {
        string text = RequireText(value: value, message: "ascii_downcase input must be a string");

        return JqValue.FromString(string.Create(length: text.Length, state: text, action: static (span, source) =>
            {
                for (int index = 0; index < source.Length; index++)
                {
                    char character = source[index];
                    span[index] = character is >= 'A' and <= 'Z' ? (char)(character + ('a' - 'A')) : character;
                }
            }));
    }

    // split(separator): an empty string splits into no parts at all
    public static IReadOnlyList<JqValue> Split(JqValue value, string separator)
    {
        string text = RequireText(value: value, message: "split input and separator must be strings");

        if (text.Length == 0)
        {
            return [];
        }

        return [.. text.Split(separator: separator, options: StringSplitOptions.None).Select(JqValue.FromString)];
    }

    // endswith(suffix)
    public static bool EndsWith(JqValue value, string suffix)
    {
        string text = RequireText(value: value, message: "endswith() requires string inputs");

        return text.EndsWith(value: suffix, comparisonType: StringComparison.Ordinal);
    }

    // rtrimstr(suffix), for a non-empty suffix
    public static JqValue RTrimStr(JqValue value, string suffix)
    {
        return EndsWith(value: value, suffix: suffix) ? JqValue.FromString(value.Text[..^suffix.Length]) : value;
    }

    // .[0:count] : a string by code points, an array by items
    public static JqValue Take(JqValue value, int count)
    {
        return value.Kind switch
        {
            JqKind.NULL => JqValue.Null,
            JqKind.TEXT => JqValue.FromString(TakeCodePoints(text: value.Text, count: count)),
            JqKind.ARRAY => JqValue.FromArray([.. value.Items.Take(count)]),
            _ => throw new JqException($"Cannot index {value.TypeName()} with object"),
        };
    }

    // .[start:] of an array
    public static JqValue Skip(JqValue value, int start)
    {
        return value.Kind switch
        {
            JqKind.NULL => JqValue.Null,
            JqKind.ARRAY => JqValue.FromArray([.. value.Items.Skip(start)]),
            _ => throw new JqException($"Cannot index {value.TypeName()} with object"),
        };
    }

    // index(item) != null, with jq's indices: an array is searched for the item (or, for an array
    // item, the run of items), a string for a non-empty substring, an object looked up by key and
    // the value's first item taken, and null finds nothing
    public static bool HasIndex(JqValue value, JqValue item)
    {
        return value.Kind switch
        {
            JqKind.NULL => false,
            JqKind.ARRAY => item.Kind == JqKind.ARRAY
                ? ContainsRun(values: value.Items, run: item.Items)
                : value.Items.Any(candidate => Equal(left: candidate, right: item)),
            JqKind.TEXT when item.Kind == JqKind.TEXT => item.Text.Length != 0
                && value.Text.Contains(value: item.Text, comparisonType: StringComparison.Ordinal),
            JqKind.DICTIONARY when item.Kind == JqKind.TEXT => FirstItem(
                JqOps.Field(value: value, name: item.Text)
            ).Kind != JqKind.NULL,
            _ => throw new JqException($"Cannot index {value.TypeName()} with {item.TypeName()}"),
        };
    }

    // group_by(f), stable as jq's sort is
    public static IReadOnlyList<IReadOnlyList<JqValue>> GroupBy(JqValue value, Func<JqValue, JqValue> key)
    {
        IReadOnlyList<(JqValue Key, JqValue Item)> keyed =
        [
            .. JqOps.Iterate(value).Select(item => (Key: JqValue.FromArray([key(item)]), Item: item)),
        ];

        if (value.Kind != JqKind.ARRAY)
        {
            throw new JqException($"{value.TypeName()} and array cannot be sorted, as they are not both arrays");
        }

        List<IReadOnlyList<JqValue>> groups = [];
        List<JqValue>? current = null;
        JqValue? currentKey = null;

        foreach (
            (JqValue groupKey, JqValue item) in keyed.OrderBy(
                keySelector: static pair => pair.Key,
                comparer: JqComparer.Instance
            )
        )
        {
            if (current is null || currentKey is null || !Equal(left: currentKey, right: groupKey))
            {
                current = [];
                groups.Add(current);
                currentKey = groupKey;
            }

            current.Add(item);
        }

        return groups;
    }

    // unique_by(f): the first item of each group_by(f) group
    public static IReadOnlyList<JqValue> UniqueBy(JqValue value, Func<JqValue, JqValue> key)
    {
        return [.. GroupBy(value: value, key: key).Select(static group => group[0])];
    }

    // min: the first of equal smallest items, or null for an empty array
    public static JqValue Min(JqValue value)
    {
        if (value.Kind != JqKind.ARRAY)
        {
            throw new JqException($"Cannot compute minimum of {value.TypeName()}");
        }

        if (value.Items.Count == 0)
        {
            return JqValue.Null;
        }

        JqValue smallest = value.Items[0];

        for (int index = 1; index < value.Items.Count; index++)
        {
            if (Compare(left: value.Items[index], right: smallest) < 0)
            {
                smallest = value.Items[index];
            }
        }

        return smallest;
    }

    // a + b, for the operands the predicates add: null leaves the other side, strings and arrays
    // concatenate, and objects merge (a key already there keeps its place and takes the new value)
    public static JqValue Add(JqValue left, JqValue right)
    {
        if (left.Kind == JqKind.NULL)
        {
            return right;
        }

        if (right.Kind == JqKind.NULL)
        {
            return left;
        }

        return (left.Kind, right.Kind) switch
        {
            (JqKind.TEXT, JqKind.TEXT) => JqValue.FromString(left.Text + right.Text),
            (JqKind.ARRAY, JqKind.ARRAY) => JqValue.FromArray([.. left.Items, .. right.Items]),
            (JqKind.DICTIONARY, JqKind.DICTIONARY) => Merge(left: left, right: right),
            _ => throw new JqException($"{left.TypeName()} and {right.TypeName()} cannot be added"),
        };
    }

    public static JqValue Add(string left, JqValue right)
    {
        return Add(left: JqValue.FromString(left), right: right);
    }

    // .name = value, and .name |= f: a key already there keeps its place
    public static JqValue SetField(JqValue value, string name, JqValue field)
    {
        if (value.Kind == JqKind.NULL)
        {
            return JqValue.FromObject([new(Name: name, Value: field)]);
        }

        if (value.Kind != JqKind.DICTIONARY)
        {
            throw new JqException($"Cannot index {value.TypeName()} with \"{name}\"");
        }

        List<JqProperty> properties = [.. value.Properties];
        int position = properties.FindIndex(property => StringComparer.Ordinal.Equals(x: property.Name, y: name));

        if (position < 0)
        {
            properties.Add(new(Name: name, Value: field));
        }
        else
        {
            properties[position] = new(Name: name, Value: field);
        }

        return JqValue.FromObject(properties);
    }

    // type
    public static bool IsKind(JqValue value, string typeName)
    {
        return StringComparer.Ordinal.Equals(x: value.TypeName(), y: typeName);
    }

    private static JqValue Merge(JqValue left, JqValue right)
    {
        JqValue merged = left;

        foreach (JqProperty property in right.Properties)
        {
            merged = SetField(value: merged, name: property.Name, field: property.Value);
        }

        return merged;
    }

    private static bool ContainsRun(IReadOnlyList<JqValue> values, IReadOnlyList<JqValue> run)
    {
        if (run.Count == 0)
        {
            return false;
        }

        for (int start = 0; start < values.Count; start++)
        {
            if (RunStartsAt(values: values, run: run, start: start))
            {
                return true;
            }
        }

        return false;
    }

    private static bool RunStartsAt(IReadOnlyList<JqValue> values, IReadOnlyList<JqValue> run, int start)
    {
        for (int offset = 0; offset < run.Count; offset++)
        {
            int position = start + offset;

            if (position >= values.Count || !Equal(left: values[position], right: run[offset]))
            {
                return false;
            }
        }

        return true;
    }

    // .[0] of what an object lookup found
    private static JqValue FirstItem(JqValue value)
    {
        return value.Kind switch
        {
            JqKind.NULL => JqValue.Null,
            JqKind.ARRAY => value.Items.Count == 0 ? JqValue.Null : value.Items[0],
            _ => throw new JqException($"Cannot index {value.TypeName()} with number"),
        };
    }

    private static string TakeCodePoints(string text, int count)
    {
        int length = 0;
        int taken = 0;

        foreach (Rune rune in text.EnumerateRunes())
        {
            if (taken == count)
            {
                break;
            }

            length += rune.Utf16SequenceLength;
            taken++;
        }

        return text[..length];
    }

    private static string RequireText(JqValue value, string message)
    {
        if (value.Kind != JqKind.TEXT)
        {
            throw new JqException(message + ", not " + value.TypeName());
        }

        return value.Text;
    }
}
