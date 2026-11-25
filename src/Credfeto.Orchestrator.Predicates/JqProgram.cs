using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// Runs a ported jq program the way jq runs one over its input
internal static class JqProgram
{
    // jq evaluates the program once for each JSON text of its input: a runtime error in one text is
    // reported and the next text still runs, while a text that is not JSON ends the input there. Its
    // exit status is the last text's: an error there fails the run, as does input that is not JSON,
    // while an error in an earlier text does not. With -e, a last text with no output leaves the
    // answer to the latest earlier text that printed without an error. A program returns null where
    // jq's would output nothing (empty).
    public static JqRun Run(string input, Func<JqValue, JqValue?> program)
    {
        JqInput stream = JqParser.ParseStream(input);
        List<JqValue> outputs = [];
        string? problem = null;
        bool lastFailed = false;
        bool? lastOutput = null;
        bool? answer = null;

        foreach (JqValue document in stream.Values)
        {
            try
            {
                JqValue? output = program(document);
                lastFailed = false;
                lastOutput = output?.IsTruthy;

                if (output is not null)
                {
                    outputs.Add(output);
                    answer = output.IsTruthy;
                }
            }
            catch (Exception exception) when (exception is JqException or RegexMatchTimeoutException)
            {
                problem ??= exception.Message;
                lastFailed = true;
                lastOutput = null;
            }
        }

        if (!stream.Complete)
        {
            problem ??= "the input is not valid JSON";
        }

        bool succeeded = stream.Complete && !lastFailed;

        return new(
            Outputs: outputs,
            Problem: problem,
            Succeeded: succeeded,
            Holds: succeeded && (lastOutput ?? answer) == true
        );
    }

    // jq -e: true only when the deciding output is neither false nor null; the problem is reported
    // when jq would have failed with an error rather than answered false
    public static PredicateAnswer Holds(JqRun run)
    {
        return new(Holds: run.Holds, Problem: run.Succeeded ? null : run.Problem);
    }

    // An --argjson value or a fromjson text: exactly one JSON text
    public static JqValue? TryParse(string json, out string? problem)
    {
        try
        {
            problem = null;

            return JqParser.Parse(json);
        }
        catch (JqException exception)
        {
            problem = exception.Message;

            return null;
        }
    }

    // What the shell's command substitution keeps of jq -r's output: every output on its own line,
    // NUL bytes dropped and the trailing newlines removed
    public static string Substituted(IEnumerable<JqValue> outputs)
    {
        StringBuilder builder = new();

        foreach (JqValue output in outputs)
        {
            builder.Append(JqFormatter.Raw(output)).Append('\n');
        }

        return builder
            .ToString()
            .Replace(oldValue: "\0", newValue: string.Empty, comparisonType: StringComparison.Ordinal)
            .TrimEnd('\n');
    }

    // def any(generator; condition) and all(...), which stop at the first item that settles them
    public static bool Any(IEnumerable<JqValue> items, Func<JqValue, bool> condition)
    {
        return items.Any(condition);
    }

    public static bool All(IEnumerable<JqValue> items, Func<JqValue, bool> condition)
    {
        return items.All(condition);
    }

    // a // b
    public static JqValue Or(JqValue value, JqValue fallback)
    {
        return JqOps.Alternative(value: value, fallback: fallback);
    }

    // .a.b
    public static JqValue Path(JqValue value, string first, string second)
    {
        return JqOps.Field(value: JqOps.Field(value: value, name: first), name: second);
    }

    // test(re) on a value jq requires to be a string
    public static bool Test(JqValue value, Regex pattern)
    {
        if (value.Kind != JqKind.TEXT)
        {
            throw new JqException($"{value.TypeName()} cannot be matched, as it is not a string");
        }

        return pattern.IsMatch(value.Text);
    }
}
