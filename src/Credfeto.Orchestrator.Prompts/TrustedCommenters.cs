using System;
using System.Text;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Prompts;

// _build_trusted_commenters_section: the header, then jq -r '.[] | "- \(.)"' over the logins JSON. Only a JSON array
// is ported (fetch_trusted_logins always prints one); for an object, a JSON stream or text jq would only partly
// read, the tool refuses and lib/prompts runs jq itself
internal static class TrustedCommenters
{
    public static string Section(PromptTemplateSet templates, string loginsJson)
    {
        if (loginsJson.Length == 0 || StringComparer.Ordinal.Equals(x: loginsJson, y: "null"))
        {
            return string.Empty;
        }

        StringBuilder text = new(BashText.Line(templates.Text("TrustedCommentersHeader")));

        foreach (JqValue login in Logins(loginsJson).Items)
        {
            string line = JqFormatter.Raw(login);

            if (line.Contains('\0', StringComparison.Ordinal))
            {
                throw new PromptException("A trusted login holds a NUL character, which bash would drop");
            }

            text.Append("- ").Append(line).Append('\n');
        }

        return text.ToString();
    }

    private static JqValue Logins(string loginsJson)
    {
        JqValue value;

        try
        {
            value = JqParser.Parse(loginsJson);
        }
        catch (JqException exception)
        {
            throw new PromptException(message: "The trusted logins are not one JSON text", innerException: exception);
        }

        return value.Kind switch
        {
            JqKind.ARRAY => value,
            JqKind.DICTIONARY => throw new PromptException("The trusted logins are a JSON object, not an array"),

            // .[] fails on null, a boolean, a number or a string, so jq prints nothing
            _ => JqValue.EmptyArray,
        };
    }
}
