using System.Collections.Generic;
using System.Text.Json;

namespace Credfeto.Orchestrator.GitHub;

// The JSON value of one tool argument: a string, a boolean flag, a number or a list of strings
public static class McpArgument
{
    public static JsonElement Of(string value)
    {
        return JsonSerializer.SerializeToElement(value: value, jsonTypeInfo: GitHubJsonContext.Default.String);
    }

    public static JsonElement Of(bool value)
    {
        return JsonSerializer.SerializeToElement(value: value, jsonTypeInfo: GitHubJsonContext.Default.Boolean);
    }

    public static JsonElement Of(int value)
    {
        return JsonSerializer.SerializeToElement(value: value, jsonTypeInfo: GitHubJsonContext.Default.Int32);
    }

    public static JsonElement Of(IReadOnlyList<string> value)
    {
        return JsonSerializer.SerializeToElement(
            value: value,
            jsonTypeInfo: GitHubJsonContext.Default.IReadOnlyListString
        );
    }
}
