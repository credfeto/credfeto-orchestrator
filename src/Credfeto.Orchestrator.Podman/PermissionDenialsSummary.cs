using System.Text;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Podman;

// The jq program of claude_result_permission_denials_summary (lib/podman), run over the parsed result: one
// "- <tool>: <detail>" line for each entry of .permission_denials when it is an array, each ended by the newline jq -r
// prints. An entry that is not an object is shown as tool malformed-denial-entry with input {"raw": <entry>}; the
// detail is .tool_input.command, else .tool_input.file_path, else the whole input as text cut to 200 code points
// with "...(truncated)" added; and each run of CR and LF in the line becomes one space.
internal static class PermissionDenialsSummary
{
    private const int MAXIMUM_DETAIL_LENGTH = 200;
    private const string TRUNCATED = "...(truncated)";

    public static string Render(JqValue? result)
    {
        if (result is null)
        {
            return string.Empty;
        }

        JqValue denials = JqOps.Field(value: result, name: "permission_denials");

        if (denials.Kind != JqKind.ARRAY)
        {
            return string.Empty;
        }

        StringBuilder output = new();

        foreach (JqValue entry in denials.Items)
        {
            AppendLine(output: output, entry: AsDenial(entry));
        }

        return output.ToString();
    }

    private static JqValue AsDenial(JqValue entry)
    {
        if (entry.Kind == JqKind.DICTIONARY)
        {
            return entry;
        }

        return JqValue.FromObject([
            new(Name: "tool_name", Value: JqValue.FromString("malformed-denial-entry")),
            new(Name: "tool_input", Value: JqValue.FromObject([new(Name: "raw", Value: entry)])),
        ]);
    }

    private static void AppendLine(StringBuilder output, JqValue entry)
    {
        JqValue tool = JqOps.Alternative(value: JqOps.Field(value: entry, name: "tool_name"), fallback: "unknown");
        JqValue input = JqOps.Alternative(
            value: JqOps.Field(value: entry, name: "tool_input"),
            fallback: JqValue.FromObject([])
        );
        string line = "- " + ClaudeResultJson.ToText(tool) + ": " + Detail(input);

        output.Append(CollapseLineBreaks(line)).Append('\n');
    }

    private static string Detail(JqValue input)
    {
        if (input.Kind == JqKind.DICTIONARY)
        {
            JqValue command = JqOps.Field(value: input, name: "command");

            if (command.IsTruthy)
            {
                return ClaudeResultJson.ToText(command);
            }

            JqValue filePath = JqOps.Field(value: input, name: "file_path");

            if (filePath.IsTruthy)
            {
                return ClaudeResultJson.ToText(filePath);
            }
        }

        return Truncate(ClaudeResultJson.ToText(input));
    }

    private static string Truncate(string text)
    {
        return ClaudeResultJson.CodePointLength(text) > MAXIMUM_DETAIL_LENGTH
            ? ClaudeResultJson.CodePointPrefix(value: text, count: MAXIMUM_DETAIL_LENGTH) + TRUNCATED
            : text;
    }

    // gsub("[\r\n]+"; " ")
    private static string CollapseLineBreaks(string line)
    {
        StringBuilder builder = new(line.Length);
        bool inBreak = false;

        foreach (char character in line)
        {
            if (character is '\r' or '\n')
            {
                if (!inBreak)
                {
                    builder.Append(' ');
                    inBreak = true;
                }

                continue;
            }

            builder.Append(character);
            inBreak = false;
        }

        return builder.ToString();
    }
}
