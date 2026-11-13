using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;

namespace Credfeto.Orchestrator.Jq;

[DebuggerDisplay("{Kind}: {Text}")]
public sealed class JqValue
{
    public static readonly JqValue Null = new(kind: JqKind.NULL, text: "null", number: 0, items: [], properties: []);

    public static readonly JqValue False = new(kind: JqKind.FALSE, text: "false", number: 0, items: [], properties: []);

    public static readonly JqValue True = new(kind: JqKind.TRUE, text: "true", number: 0, items: [], properties: []);

    public static readonly JqValue EmptyArray = FromArray([]);

    private JqValue(
        JqKind kind,
        string text,
        double number,
        IReadOnlyList<JqValue> items,
        IReadOnlyList<JqProperty> properties
    )
    {
        this.Kind = kind;
        this.Text = text;
        this.Number = number;
        this.Items = items;
        this.Properties = properties;
    }

    public JqKind Kind { get; }

    // The string itself for a string; jq's canonical literal for a number
    public string Text { get; }

    public double Number { get; }

    public IReadOnlyList<JqValue> Items { get; }

    public IReadOnlyList<JqProperty> Properties { get; }

    public bool IsTruthy => this.Kind is not (JqKind.NULL or JqKind.FALSE);

    public static JqValue FromString(string value)
    {
        return new(kind: JqKind.TEXT, text: value, number: 0, items: [], properties: []);
    }

    public static JqValue FromBoolean(bool value)
    {
        return value ? True : False;
    }

    public static JqValue FromNumberLiteral(string literal)
    {
        return new(
            kind: JqKind.NUMBER,
            text: JqNumber.Canonicalise(literal),
            number: double.Parse(s: literal, style: NumberStyles.Float, provider: CultureInfo.InvariantCulture),
            items: [],
            properties: []
        );
    }

    public static JqValue FromInteger(long value)
    {
        string literal = value.ToString(CultureInfo.InvariantCulture);

        return FromNumberLiteral(literal);
    }

    public static JqValue FromArray(IReadOnlyList<JqValue> items)
    {
        return new(kind: JqKind.ARRAY, text: string.Empty, number: 0, items: items, properties: []);
    }

    public static JqValue FromObject(IReadOnlyList<JqProperty> properties)
    {
        return new(kind: JqKind.DICTIONARY, text: string.Empty, number: 0, items: [], properties: properties);
    }

    public string TypeName()
    {
        return this.Kind switch
        {
            JqKind.NULL => "null",
            JqKind.FALSE or JqKind.TRUE => "boolean",
            JqKind.NUMBER => "number",
            JqKind.TEXT => "string",
            JqKind.ARRAY => "array",
            _ => "object",
        };
    }
}
