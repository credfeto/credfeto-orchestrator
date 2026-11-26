using System;
using System.Linq;
using System.Text;
using System.Text.Json;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Podman;

// The jq semantics the two result programs rely on, and the inputs where the tool will not claim jq's answer
internal static class ClaudeResultJson
{
    private const int MAXIMUM_PLAIN_INTEGER_DIGITS = 15;

    // The parse and the printing recurse once a level, so a deeper document is refused rather than risking the stack
    private const int MAXIMUM_DEPTH = 1000;

    private static readonly JsonReaderOptions ScanOptions = new()
    {
        AllowMultipleValues = true,
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = MAXIMUM_DEPTH,
    };

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    // The one JSON text in the file, or null when it holds none (jq then runs the program zero times and prints
    // nothing). Refused: bytes that are not UTF-8 (jq reads them as U+FFFD), anything System.Text.Json does not parse
    // as a stream of JSON texts (jq's parser takes more, a byte order mark, nan, raw control characters, and stops
    // at different places), more than one text (jq runs the program once a text), and a top-level value the
    // programs' first .permission_denials fails on
    public static JqValue? Parse(byte[] json)
    {
        string text;

        try
        {
            text = Utf8.GetString(json);
        }
        catch (DecoderFallbackException exception)
        {
            throw new PodmanRefusedException(
                message: "the result file is not UTF-8, which jq reads with replacement characters",
                innerException: exception
            );
        }

        RefuseUnreadable(json);
        JqInput input = ParseStream(text);

        if (!input.Complete)
        {
            throw new PodmanRefusedException("the result file is not JSON the tool parses exactly as jq does");
        }

        if (input.Values.Count == 0)
        {
            return null;
        }

        if (input.Values.Count != 1)
        {
            throw new PodmanRefusedException("the result file holds more than one JSON text");
        }

        JqValue result = input.Values[0];

        if (result.Kind is not (JqKind.DICTIONARY or JqKind.NULL))
        {
            throw new PodmanRefusedException($"jq cannot index {result.TypeName()} with \"permission_denials\"");
        }

        return result;
    }

    // tostring, and what string interpolation inserts: a string as itself, anything else as compact JSON
    public static string ToText(JqValue value)
    {
        if (value.Kind == JqKind.TEXT)
        {
            return value.Text;
        }

        RefuseNumbers(value);

        return JqFormatter.ToJson(value);
    }

    // length of a string: its code points
    public static int CodePointLength(string value)
    {
        return value.EnumerateRunes().Count();
    }

    // .[0:count] of a string: its first count code points
    public static string CodePointPrefix(string value, int count)
    {
        int end = 0;

        foreach (Rune rune in value.EnumerateRunes().Take(count))
        {
            end += rune.Utf16SequenceLength;
        }

        return value[..end];
    }

    // A document System.Text.Json will not read, or nested more than MAXIMUM_DEPTH levels deep
    private static void RefuseUnreadable(byte[] json)
    {
        Utf8JsonReader reader = new(jsonData: json, options: ScanOptions);

        try
        {
            while (reader.Read())
            {
                // Reading every token checks the syntax and the depth
            }
        }
        catch (JsonException exception)
        {
            throw new PodmanRefusedException(
                message: "the result file is not JSON the tool parses exactly as jq does: " + exception.Message,
                innerException: exception
            );
        }
    }

    private static JqInput ParseStream(string text)
    {
        try
        {
            return JqParser.ParseStream(text);
        }
        catch (Exception exception) when (exception is OverflowException or FormatException or JqException)
        {
            throw new PodmanRefusedException(
                message: "the result file holds a number the tool cannot read: " + exception.Message,
                innerException: exception
            );
        }
    }

    // jq prints a number from its literal; the tool claims that form only for a plain integer of up to 15 digits
    private static void RefuseNumbers(JqValue value)
    {
        switch (value.Kind)
        {
            case JqKind.NUMBER when !IsPlainInteger(value.Text):
                throw new PodmanRefusedException(
                    $"jq would print the number {value.Text}, which the tool does not claim to print as jq does"
                );
            case JqKind.ARRAY:
                foreach (JqValue item in value.Items)
                {
                    RefuseNumbers(item);
                }

                break;
            case JqKind.DICTIONARY:
                foreach (JqProperty property in value.Properties)
                {
                    RefuseNumbers(property.Value);
                }

                break;
        }
    }

    private static bool IsPlainInteger(string literal)
    {
        ReadOnlySpan<char> digits = literal.AsSpan();

        if (!digits.IsEmpty && digits[0] == '-')
        {
            digits = digits[1..];
        }

        return digits.Length is > 0 and <= MAXIMUM_PLAIN_INTEGER_DIGITS
            && !digits.ContainsAnyExceptInRange(lowInclusive: '0', highInclusive: '9')
            && (digits[0] != '0' || StringComparer.Ordinal.Equals(x: literal, y: "0"));
    }
}
