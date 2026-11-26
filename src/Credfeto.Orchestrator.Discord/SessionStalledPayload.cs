using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// The session-stalled payload lib/discord builds: the item, its denial count and denied command names, then the final
// message with tokens and anything path-like masked before it is cut, as the jq program's masked def does with four
// gsub calls (Oniguruma, no flags). The patterns spell out ASCII classes and Oniguruma's Unicode White_Space set for
// \s, so neither the culture nor the runtime's own idea of a space changes what they match.
public static partial class SessionStalledPayload
{
    // The Discord embed colour lib/discord passes as --argjson color
    public const long Orange = 15105570;

    public const string NoCommandsText = "none";
    public const string EmptyMessageText = "(empty)";

    private const string TITLE_PREFIX = "Session stalled: ";
    private const int TITLE_LENGTH = 240;
    private const int COMMANDS_LENGTH = 1000;
    private const int MESSAGE_LENGTH = 240;

    private const string TOKEN = "[token]";
    private const string PATH = "[path]";

    // A pattern that backtracks for longer than this on a huge message is left to jq
    private const int MATCH_TIMEOUT_MILLISECONDS = 10000;

    // Everything but Oniguruma's \s: U+0009-U+000D, space, U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029,
    // U+202F, U+205F and U+3000
    private const string NOT_SPACE = @"[^\t-\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]";

    public static JqValue Build(IReadOnlyDictionary<string, string> options)
    {
        string commands = options[DiscordCommandParser.Commands];
        string message = options[DiscordCommandParser.Message];

        return DiscordPayloads.Embed(
            Property(
                name: "title",
                value: Take(text: TITLE_PREFIX + options[DiscordCommandParser.Repository], count: TITLE_LENGTH)
            ),
            Property(name: "url", value: DiscordPayloads.Text(options: options, name: DiscordCommandParser.Link)),
            Property(name: "color", value: JqValue.FromInteger(Orange)),
            Property(
                name: "fields",
                value: JqValue.FromArray([
                    DiscordPayloads.Field(
                        name: "Item",
                        value: DiscordPayloads.Text(options: options, name: DiscordCommandParser.Item),
                        inline: true
                    ),
                    DiscordPayloads.Field(
                        name: "Denials",
                        value: DiscordPayloads.Text(options: options, name: DiscordCommandParser.Count),
                        inline: true
                    ),
                    DiscordPayloads.Field(
                        name: "Denied commands",
                        value: commands.Length == 0
                            ? JqValue.FromString(NoCommandsText)
                            : Take(text: ListCommands(commands), count: COMMANDS_LENGTH),
                        inline: false
                    ),
                    DiscordPayloads.Field(
                        name: "Final message",
                        value: message.Length == 0
                            ? JqValue.FromString(EmptyMessageText)
                            : Take(text: Mask(message), count: MESSAGE_LENGTH),
                        inline: false
                    ),
                ])
            )
        );
    }

    // The masked def: GitHub tokens, then hex runs of 32 or more, then any run of non-space with a / in it, then any
    // other run of 40 or more token characters, each replaced left to right without overlaps
    public static string Mask(string message)
    {
        try
        {
            string masked = GitHubToken().Replace(input: message, replacement: TOKEN);
            masked = LongHex().Replace(input: masked, replacement: TOKEN);
            masked = PathLike().Replace(input: masked, replacement: PATH);

            return LongToken().Replace(input: masked, replacement: TOKEN);
        }
        catch (RegexMatchTimeoutException exception)
        {
            throw new DiscordRefusedException(
                message: "the final message took too long to mask",
                innerException: exception
            );
        }
    }

    // split(",") | join(", "): every comma, a leading or trailing one included, gains a space
    private static string ListCommands(string commands)
    {
        return commands.Replace(oldValue: ",", newValue: ", ", comparisonType: StringComparison.Ordinal);
    }

    private static JqValue Take(string text, int count)
    {
        return JqBuiltins.Take(value: JqValue.FromString(text), count: count);
    }

    private static JqProperty Property(string name, JqValue value)
    {
        return new(Name: name, Value: value);
    }

    [GeneratedRegex(
        pattern: "(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+",
        options: RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex GitHubToken();

    [GeneratedRegex(
        pattern: "[0-9a-fA-F]{32,}",
        options: RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex LongHex();

    [GeneratedRegex(
        pattern: NOT_SPACE + "*/" + NOT_SPACE + "*",
        options: RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex PathLike();

    [GeneratedRegex(
        pattern: "[A-Za-z0-9+=_-]{40,}",
        options: RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex LongToken();
}
