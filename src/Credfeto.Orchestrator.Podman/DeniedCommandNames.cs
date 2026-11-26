using System;
using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Podman;

// The jq program of claude_result_denied_command_names (lib/podman), run over the parsed result: the name of each
// object entry of .permission_denials (when it is an array), sorted, de-duplicated and comma-joined, then the newline
// jq -r prints. A Bash entry names the program its command runs (ShellProgramWord); any other entry its tool name as
// text. A name that is not a plain short one is "(other)".
internal static class DeniedCommandNames
{
    private const int MAXIMUM_PROGRAM_TAIL = 39;
    private const int MAXIMUM_TOOL_TAIL = 59;
    private const string OTHER = "(other)";

    public static string Read(JqValue? result)
    {
        if (result is null)
        {
            return string.Empty;
        }

        JqValue denials = JqOps.Alternative(
            value: JqOps.Field(value: result, name: "permission_denials"),
            fallback: JqValue.EmptyArray
        );

        IEnumerable<JqValue> entries = denials.Kind == JqKind.ARRAY ? denials.Items : [];
        IEnumerable<string> names = entries
            .Where(static entry => entry.Kind == JqKind.DICTIONARY)
            .Select(Name)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal);

        return string.Join(separator: ',', values: names) + "\n";
    }

    private static string Name(JqValue entry)
    {
        JqValue tool = JqOps.Field(value: entry, name: "tool_name");

        if (JqBuiltins.Equal(left: tool, right: "Bash"))
        {
            return ProgramName(entry);
        }

        return PlainName(
            name: ClaudeResultJson.ToText(JqOps.Alternative(value: tool, fallback: string.Empty)),
            others: "_.+-",
            maximumTail: MAXIMUM_TOOL_TAIL
        );
    }

    private static string ProgramName(JqValue entry)
    {
        JqValue input = JqOps.Alternative(
            value: JqOps.Field(value: entry, name: "tool_input"),
            fallback: JqValue.FromObject([])
        );
        JqValue command =
            input.Kind == JqKind.DICTIONARY
                ? JqOps.Alternative(value: JqOps.Field(value: input, name: "command"), fallback: string.Empty)
                : JqValue.FromString(string.Empty);

        // sub("^[({\"']+"; "") | sub("[\"')}]+$"; ""): the word holds no newline, so $ is its end
        string word = ShellProgramWord
            .Find(ClaudeResultJson.ToText(command))
            .AsSpan()
            .TrimStart("({\"'")
            .TrimEnd("\"')}")
            .ToString();

        // split("/") | last // "": nothing for an empty word, else what follows the last slash
        string basename = word.Length == 0 ? string.Empty : word[(word.AsSpan().LastIndexOf('/') + 1)..];

        return PlainName(name: basename, others: "._+-", maximumTail: MAXIMUM_PROGRAM_TAIL);
    }

    // plain_name: the name when it matches ^[A-Za-z0-9][A-Za-z0-9<others>]{0,tail}$, else (other). Oniguruma's $, as
    // jq uses it, also matches before a newline that ends the text, so that newline is allowed and kept.
    private static string PlainName(string name, string others, int maximumTail)
    {
        ReadOnlySpan<char> core = name.AsSpan();

        if (!core.IsEmpty && core[^1] == '\n')
        {
            core = core[..^1];
        }

        if (core.IsEmpty || core.Length > maximumTail + 1 || !IsAsciiLetterOrDigit(core[0]))
        {
            return OTHER;
        }

        foreach (char character in core[1..])
        {
            if (!IsAsciiLetterOrDigit(character) && !others.Contains(character, StringComparison.Ordinal))
            {
                return OTHER;
            }
        }

        return name;
    }

    private static bool IsAsciiLetterOrDigit(char character)
    {
        return char.IsAsciiLetterOrDigit(character);
    }
}
