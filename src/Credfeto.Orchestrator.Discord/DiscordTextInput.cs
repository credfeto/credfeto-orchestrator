using System;
using System.Text;
using System.Text.Json;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// The input a lib/discord text function hands the tool in a here-string: exactly the text it would pipe to jq,
// followed by the one newline the here-string adds
public static class DiscordTextInput
{
    // Far deeper than the flat lists these functions read, and shallow enough that the recursive parse and checks
    // never come near the stack limit
    private const int MAXIMUM_DEPTH = 64;

    private const char REPLACEMENT = '\uFFFD';
    private const char BYTE_ORDER_MARK = '\uFEFF';

    private static readonly UTF8Encoding Strict = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true
    );

    private static readonly JsonReaderOptions DepthCheck = new()
    {
        AllowMultipleValues = true,
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = MAXIMUM_DEPTH,
    };

    // The text with the here-string's newline dropped. Refuses bytes that are not UTF-8 (jq would put U+FFFD in
    // their place, possibly not as .NET would), a byte order mark (jq skips one when it parses JSON) and NUL (which
    // no bash variable holds)
    public static string Text(ReadOnlySpan<byte> input)
    {
        if (input.Length == 0 || input[^1] != (byte)'\n')
        {
            throw new DiscordRefusedException("the input does not end with the newline a here-string adds");
        }

        string text;

        try
        {
            text = Strict.GetString(input[..^1]);
        }
        catch (DecoderFallbackException exception)
        {
            throw new DiscordRefusedException(message: "the input is not UTF-8", innerException: exception);
        }

        if (text.Length > 0 && text[0] == BYTE_ORDER_MARK)
        {
            throw new DiscordRefusedException("the input starts with a byte order mark");
        }

        if (text.Contains('\0', StringComparison.Ordinal))
        {
            throw new DiscordRefusedException("the input holds a NUL");
        }

        return text;
    }

    // Every JSON text of the input, as jq reads them, when the tool can be sure jq reads them the same: anything
    // System.Text.Json will not parse (jq's parser is laxer), nesting deeper than MAXIMUM_DEPTH, a string holding
    // U+FFFD (jq's stand-in for a lone surrogate escape) and a number jq might print differently are refused
    public static JqInput Json(string text)
    {
        if (CountTokens(text) == 0)
        {
            return new(Values: [], Complete: true);
        }

        JqInput input = JqParser.ParseStream(text);

        if (!input.Complete)
        {
            throw new DiscordRefusedException("the input is not JSON the tool reads exactly as jq does");
        }

        foreach (JqValue value in input.Values)
        {
            CheckValue(value);
        }

        return input;
    }

    // A number jq prints as written: a plain integer of at most 15 digits
    public static bool IsPlainInteger(string text)
    {
        bool negative = text.Length > 0 && text[0] == '-';

        return DiscordPayloads.IsPlainInteger(digits: negative ? text.AsSpan(1) : text.AsSpan(), negative: negative);
    }

    // A string argument the runtime decoded from bytes that were not UTF-8 holds U+FFFD, which jq may place
    // differently
    public static void RefuseReplaced(string value)
    {
        if (value.Contains(REPLACEMENT, StringComparison.Ordinal))
        {
            throw new DiscordRefusedException("an argument is not UTF-8");
        }
    }

    // How many JSON tokens the input holds; the reader throws past MAXIMUM_DEPTH or on JSON it will not parse
    private static int CountTokens(string text)
    {
        Utf8JsonReader reader = new(jsonData: Encoding.UTF8.GetBytes(text), options: DepthCheck);

        try
        {
            int tokens = 0;

            while (reader.Read())
            {
                tokens++;
            }

            return tokens;
        }
        catch (JsonException exception)
        {
            throw new DiscordRefusedException(
                message: "the input is not JSON the tool reads exactly as jq does",
                innerException: exception
            );
        }
    }

    private static void CheckValue(JqValue value)
    {
        switch (value.Kind)
        {
            case JqKind.TEXT:
                CheckText(value.Text);

                break;
            case JqKind.NUMBER when !IsPlainInteger(value.Text):
                throw new DiscordRefusedException("the input holds a number jq might print differently");
            case JqKind.ARRAY:
                CheckItems(value);

                break;
            case JqKind.DICTIONARY:
                CheckProperties(value);

                break;
            default:
                break;
        }
    }

    private static void CheckItems(JqValue value)
    {
        foreach (JqValue item in value.Items)
        {
            CheckValue(item);
        }
    }

    private static void CheckProperties(JqValue value)
    {
        foreach (JqProperty property in value.Properties)
        {
            CheckText(property.Name);
            CheckValue(property.Value);
        }
    }

    private static void CheckText(string text)
    {
        if (text.Contains(REPLACEMENT, StringComparison.Ordinal))
        {
            throw new DiscordRefusedException(
                "the input holds U+FFFD, which jq also puts in place of a lone surrogate"
            );
        }
    }
}
