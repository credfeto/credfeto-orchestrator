using System.Globalization;
using System.Text;

namespace Credfeto.Orchestrator.Jq;

public static class JqFormatter
{
    private const char FIRST_PRINTABLE = ' ';
    private const char DELETE = '\u007f';

    // jq -r: a string prints as itself, anything else as compact JSON
    public static string Raw(JqValue value)
    {
        return value.Kind == JqKind.TEXT ? value.Text : ToJson(value);
    }

    // jq tojson / -c
    public static string ToJson(JqValue value)
    {
        StringBuilder builder = new();
        Append(builder: builder, value: value);

        return builder.ToString();
    }

    // jq's default output: each level indented by two more spaces, a space after the colon of each key, and an
    // empty array or object kept on one line
    public static string ToIndentedJson(JqValue value)
    {
        StringBuilder builder = new();
        AppendIndented(builder: builder, value: value, depth: 0);

        return builder.ToString();
    }

    private static void AppendIndented(StringBuilder builder, JqValue value, int depth)
    {
        if (value.Kind == JqKind.ARRAY && value.Items.Count != 0)
        {
            builder.Append('[');

            for (int index = 0; index < value.Items.Count; index++)
            {
                StartLine(builder: builder, index: index, depth: depth + 1);
                AppendIndented(builder: builder, value: value.Items[index], depth: depth + 1);
            }

            NewLine(builder: builder, depth: depth).Append(']');
        }
        else if (value.Kind == JqKind.DICTIONARY && value.Properties.Count != 0)
        {
            builder.Append('{');

            for (int index = 0; index < value.Properties.Count; index++)
            {
                StartLine(builder: builder, index: index, depth: depth + 1);
                JqProperty property = value.Properties[index];
                AppendString(builder: builder, value: property.Name);
                builder.Append(": ");
                AppendIndented(builder: builder, value: property.Value, depth: depth + 1);
            }

            NewLine(builder: builder, depth: depth).Append('}');
        }
        else
        {
            Append(builder: builder, value: value);
        }
    }

    private static void StartLine(StringBuilder builder, int index, int depth)
    {
        if (index != 0)
        {
            builder.Append(',');
        }

        NewLine(builder: builder, depth: depth);
    }

    private static StringBuilder NewLine(StringBuilder builder, int depth)
    {
        return builder.Append('\n').Append(value: ' ', repeatCount: depth * 2);
    }

    private static void Append(StringBuilder builder, JqValue value)
    {
        switch (value.Kind)
        {
            case JqKind.NULL:
            case JqKind.FALSE:
            case JqKind.TRUE:
            case JqKind.NUMBER:
                builder.Append(value.Text);

                break;
            case JqKind.TEXT:
                AppendString(builder: builder, value: value.Text);

                break;
            case JqKind.ARRAY:
                AppendArray(builder: builder, value: value);

                break;
            default:
                AppendObject(builder: builder, value: value);

                break;
        }
    }

    private static void AppendArray(StringBuilder builder, JqValue value)
    {
        builder.Append('[');

        for (int index = 0; index < value.Items.Count; index++)
        {
            if (index != 0)
            {
                builder.Append(',');
            }

            Append(builder: builder, value: value.Items[index]);
        }

        builder.Append(']');
    }

    private static void AppendObject(StringBuilder builder, JqValue value)
    {
        builder.Append('{');

        for (int index = 0; index < value.Properties.Count; index++)
        {
            if (index != 0)
            {
                builder.Append(',');
            }

            JqProperty property = value.Properties[index];
            AppendString(builder: builder, value: property.Name);
            builder.Append(':');
            Append(builder: builder, value: property.Value);
        }

        builder.Append('}');
    }

    private static void AppendString(StringBuilder builder, string value)
    {
        builder.Append('"');

        foreach (char character in value)
        {
            AppendCharacter(builder: builder, character: character);
        }

        builder.Append('"');
    }

    private static void AppendCharacter(StringBuilder builder, char character)
    {
        switch (character)
        {
            case '"':
                builder.Append("\\\"");

                break;
            case '\\':
                builder.Append("\\\\");

                break;
            case '\n':
                builder.Append("\\n");

                break;
            case '\t':
                builder.Append("\\t");

                break;
            case '\r':
                builder.Append("\\r");

                break;
            case '\b':
                builder.Append("\\b");

                break;
            case '\f':
                builder.Append("\\f");

                break;
            default:
                if (character is < FIRST_PRINTABLE or DELETE)
                {
                    builder
                        .Append("\\u")
                        .Append(((int)character).ToString(format: "x4", provider: CultureInfo.InvariantCulture));
                }
                else
                {
                    builder.Append(character);
                }

                break;
        }
    }
}
