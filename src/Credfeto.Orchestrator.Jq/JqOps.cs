using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Credfeto.Orchestrator.Jq;

// The jq builtins the fingerprint filters use, with jq 1.7+ semantics, including where jq fails
public static class JqOps
{
    // .name
    public static JqValue Field(JqValue value, string name)
    {
        if (value.Kind == JqKind.NULL)
        {
            return JqValue.Null;
        }

        if (value.Kind != JqKind.DICTIONARY)
        {
            throw new JqException($"Cannot index {value.TypeName()} with \"{name}\"");
        }

        return value
                .Properties.Where(property => StringComparer.Ordinal.Equals(x: property.Name, y: name))
                .Select(static property => property.Value)
                .FirstOrDefault()
            ?? JqValue.Null;
    }

    // a // b
    public static JqValue Alternative(JqValue value, JqValue fallback)
    {
        return value.IsTruthy ? value : fallback;
    }

    // a // "text"
    public static JqValue Alternative(JqValue value, string fallback)
    {
        return value.IsTruthy ? value : JqValue.FromString(fallback);
    }

    // .[]
    public static IReadOnlyList<JqValue> Iterate(JqValue value)
    {
        return value.Kind switch
        {
            JqKind.ARRAY => value.Items,
            JqKind.DICTIONARY => [.. value.Properties.Select(static property => property.Value)],
            _ => throw new JqException($"Cannot iterate over {value.TypeName()}"),
        };
    }

    // map(select(predicate))
    public static JqValue Filter(JqValue value, Func<JqValue, bool> predicate)
    {
        return JqValue.FromArray([.. Iterate(value).Where(predicate)]);
    }

    // length
    public static JqValue Length(JqValue value)
    {
        return value.Kind switch
        {
            JqKind.NULL => JqValue.FromInteger(0),
            JqKind.NUMBER => value.Number < 0 ? JqValue.FromNumberLiteral(value.Text[1..]) : value,
            JqKind.TEXT => JqValue.FromInteger(value.Text.EnumerateRunes().Count()),
            JqKind.ARRAY => JqValue.FromInteger(value.Items.Count),
            JqKind.DICTIONARY => JqValue.FromInteger(value.Properties.Count),
            _ => throw new JqException($"{value.TypeName()} has no length"),
        };
    }

    // [...] | sort
    public static IReadOnlyList<JqValue> Sort(IEnumerable<JqValue> values)
    {
        return [.. values.Order(JqComparer.Instance)];
    }

    // sort_by(key): stable, like jq
    public static JqValue SortBy(JqValue value, Func<JqValue, JqValue> key)
    {
        if (value.Kind != JqKind.ARRAY)
        {
            throw new JqException($"{value.TypeName()} cannot be sorted, as it is not an array");
        }

        return JqValue.FromArray([
            .. value
                .Items.Select(item => (Key: key(item), Item: item))
                .OrderBy(keySelector: static pair => pair.Key, comparer: JqComparer.Instance)
                .Select(static pair => pair.Item),
        ]);
    }

    // last
    public static JqValue Last(JqValue value)
    {
        return value.Kind switch
        {
            JqKind.NULL => JqValue.Null,
            JqKind.ARRAY => value.Items.Count == 0 ? JqValue.Null : value.Items[^1],
            _ => throw new JqException($"Cannot index {value.TypeName()} with number"),
        };
    }

    // tostring, and the value of a string interpolation
    public static string ToText(JqValue value)
    {
        return JqFormatter.Raw(value);
    }

    // @tsv
    public static string Tsv(IReadOnlyList<JqValue> row)
    {
        return string.Join(separator: '\t', values: row.Select(TsvField));
    }

    // join(separator)
    public static string Join(IReadOnlyList<JqValue> values, string separator)
    {
        StringBuilder builder = new();

        for (int index = 0; index < values.Count; index++)
        {
            if (index != 0)
            {
                builder.Append(separator);
            }

            builder.Append(JoinField(values[index]));
        }

        return builder.ToString();
    }

    // $trusted | index($login) != null, for the array of trusted logins
    public static bool Contains(JqValue values, JqValue item)
    {
        if (values.Kind != JqKind.ARRAY)
        {
            throw new JqException($"Trusted logins must be an array or null, not {values.TypeName()}");
        }

        return values.Items.Any(candidate => JqComparer.Instance.Compare(x: candidate, y: item) == 0);
    }

    private static string TsvField(JqValue value)
    {
        return value.Kind switch
        {
            JqKind.NULL => string.Empty,
            JqKind.FALSE or JqKind.TRUE or JqKind.NUMBER => value.Text,
            JqKind.TEXT => value
                .Text.Replace(oldValue: "\\", newValue: "\\\\", comparisonType: StringComparison.Ordinal)
                .Replace(oldValue: "\t", newValue: "\\t", comparisonType: StringComparison.Ordinal)
                .Replace(oldValue: "\n", newValue: "\\n", comparisonType: StringComparison.Ordinal)
                .Replace(oldValue: "\r", newValue: "\\r", comparisonType: StringComparison.Ordinal)
                .Replace(oldValue: "\0", newValue: "\\0", comparisonType: StringComparison.Ordinal),
            _ => throw new JqException($"{value.TypeName()} is not valid in a csv row"),
        };
    }

    private static string JoinField(JqValue value)
    {
        return value.Kind switch
        {
            JqKind.NULL => string.Empty,
            JqKind.FALSE or JqKind.TRUE or JqKind.NUMBER or JqKind.TEXT => value.Text,
            _ => throw new JqException($"string and {value.TypeName()} cannot be added"),
        };
    }
}
