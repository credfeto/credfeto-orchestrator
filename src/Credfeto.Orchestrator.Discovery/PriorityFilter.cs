using System;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discovery;

public static class PriorityFilter
{
    // fetch_all_priorities' jq -c '[.priorities[] | select((.status == "Open" or .status == "Draft") and .isOnHold ==
    // false)]': the actionable items in feed order, as compact JSON. Returns null for a body holding no JSON value at
    // all, for which jq prints nothing and succeeds. Throws JqException where jq fails: a body that is not JSON (or
    // holds more than one value, which jq would print a line for before failing), no priorities to iterate, or an item
    // that is not an object or null
    public static string? Filter(string body)
    {
        if (IsBlank(body))
        {
            return null;
        }

        JqValue feed = JqParser.Parse(body);
        JqValue items = JqOps.Field(value: feed, name: "priorities");

        return JqFormatter.ToJson(JqValue.FromArray([.. JqOps.Iterate(items).Where(IsActionable)]));
    }

    private static bool IsActionable(JqValue item)
    {
        JqValue status = JqOps.Field(value: item, name: "status");

        return (IsText(value: status, text: "Open") || IsText(value: status, text: "Draft"))
            && JqOps.Field(value: item, name: "isOnHold").Kind == JqKind.FALSE;
    }

    private static bool IsText(JqValue value, string text)
    {
        return value.Kind == JqKind.TEXT && StringComparer.Ordinal.Equals(x: value.Text, y: text);
    }

    // jq skips JSON whitespace between values
    private static bool IsBlank(string body)
    {
        return body.All(static character => character is ' ' or '\t' or '\n' or '\r');
    }
}
