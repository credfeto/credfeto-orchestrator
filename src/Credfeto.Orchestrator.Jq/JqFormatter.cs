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
