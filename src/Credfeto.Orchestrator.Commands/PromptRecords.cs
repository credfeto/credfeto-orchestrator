using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Credfeto.Orchestrator.Commands;

// A prompt's inputs: name=value records on stdin, each ended by a NUL byte (printf '%s\0' in lib/prompts), so a value
// can hold any text bash can. Every name the prompt kind reads must be there exactly once; wf-status may repeat
public sealed class PromptRecords
{
    public const string Status = "wf-status";

    private static readonly Encoding StrictUtf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true
    );

    private readonly Dictionary<string, string> _values;

    private PromptRecords(Dictionary<string, string> values, IReadOnlyList<string> statuses)
    {
        this._values = values;
        this.Statuses = statuses;
    }

    public IReadOnlyList<string> Statuses { get; }

    public string this[string name] => this._values[name];

    // Null with the problem when the input is not records of exactly these names. Text that is not valid UTF-8
    // throws DecoderFallbackException: the tool cannot print it back byte for byte
    public static PromptRecords? Parse(ReadOnlySpan<byte> input, IReadOnlyList<string> names, out string problem)
    {
        string text = StrictUtf8.GetString(input);

        if (text.Length != 0 && text[^1] != '\0')
        {
            problem = "the last record is not ended by a NUL byte";

            return null;
        }

        Dictionary<string, string> values = [with(StringComparer.Ordinal)];
        List<string> statuses = [];

        foreach (string record in text.Split('\0')[..^1])
        {
            int equals = record.IndexOf('=', StringComparison.Ordinal);
            string name = equals < 0 ? record : record[..equals];

            if (equals < 0 || !Accepts(names: names, name: name))
            {
                problem = $"unexpected record '{name}'";

                return null;
            }

            string value = record[(equals + 1)..];

            if (StringComparer.Ordinal.Equals(x: name, y: Status))
            {
                statuses.Add(value);
            }
            else if (!values.TryAdd(key: name, value: value))
            {
                problem = $"record '{name}' is given more than once";

                return null;
            }
        }

        return Complete(values: values, statuses: statuses, names: names, problem: out problem);
    }

    private static PromptRecords? Complete(
        Dictionary<string, string> values,
        List<string> statuses,
        IReadOnlyList<string> names,
        out string problem
    )
    {
        string? missing = names.FirstOrDefault(name =>
            !StringComparer.Ordinal.Equals(x: name, y: Status) && !values.ContainsKey(name)
        );

        if (missing is not null)
        {
            problem = $"record '{missing}' is missing";

            return null;
        }

        problem = string.Empty;

        return new(values: values, statuses: statuses);
    }

    private static bool Accepts(IReadOnlyList<string> names, string name)
    {
        return names.Contains(value: name, comparer: StringComparer.Ordinal);
    }
}
