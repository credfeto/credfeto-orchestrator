using System.Collections.Generic;

namespace Credfeto.Orchestrator.Prompts;

internal static class TemplateValueList
{
    // A $(helper) in a heredoc: the helper's output without its trailing newlines
    public static void AddOutput(this List<TemplateValue> values, string name, string output)
    {
        values.Add(new(Name: name, Value: BashText.Substitution(output)));
    }

    // A ${variable} in a heredoc: the value as it is
    public static void AddValue(this List<TemplateValue> values, string name, string value)
    {
        values.Add(new(Name: name, Value: value));
    }
}
