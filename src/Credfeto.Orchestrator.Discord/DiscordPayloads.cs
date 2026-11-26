using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// The webhook payloads lib/discord builds with jq --null-input: each mirrors its jq program, object keys in the same
// order, --arg values as strings and --argjson values as numbers
public static class DiscordPayloads
{
    // Discord embed colours lib/discord passes as --argjson color
    public const long Red = 15158332;
    public const long Blue = 3447003;
    public const long Gold = 15844367;
    public const long Yellow = 16776960;

    // The fixed texts of the jq programs
    public const string BoardConversionFailedText =
        "The repository is skipped until its Workflow board has been converted to the built-in Status field. Its"
        + " Workflow Status field is kept, so no value is lost.";

    public const string BlockedIssueReplanningText =
        "The Issue is Blocked but has no Implementation Plan comment, so nothing is waiting for approval. It is being"
        + " re-invoked to plan once in this Blocked spell.";

    public const string PrNeedsApprovalText =
        "Auto-merge is armed and all required checks pass, but this PR has no approving review — it cannot merge"
        + " until a human approves it.";

    // The longest integer the tool passes on: jq keeps any number literal as written, but a longer one is not worth
    // the risk of a different rendering
    private const int MAX_DIGITS = 15;

    public static JqValue Build(DiscordCommand command)
    {
        RefuseReplacedArguments(command);
        IReadOnlyDictionary<string, string> options = command.Options;

        return command.Kind switch
        {
            DiscordPayloadKind.WORK_ITEM => WorkItem(options),
            DiscordPayloadKind.NO_WORK => NoWork(options),
            DiscordPayloadKind.LOW_DISK_SPACE => LowDiskSpace(options),
            DiscordPayloadKind.HOST_HEALTH => Embed(
                Property(name: "title", value: Text(options: options, name: DiscordCommandParser.Title)),
                Property(name: "color", value: JqValue.FromInteger(Red)),
                Property(name: "description", value: Text(options: options, name: DiscordCommandParser.Message))
            ),
            DiscordPayloadKind.SLOW_PULL => SlowPull(options),
            DiscordPayloadKind.ITEM_ERROR => ItemError(options),
            DiscordPayloadKind.BOARD_CONVERSION_FAILED => BoardConversionFailed(options),
            DiscordPayloadKind.SELF_UPDATE_STALE => SelfUpdateStale(options),
            DiscordPayloadKind.PRIORITIES_UNREACHABLE => PrioritiesUnreachable(options),
            DiscordPayloadKind.BLOCKED_ITEM => BlockedItem(options),
            DiscordPayloadKind.BLOCKED_ISSUE_REPLANNING => BlockedIssueReplanning(options),
            DiscordPayloadKind.PR_NEEDS_APPROVAL => PrNeedsApproval(options),
            DiscordPayloadKind.PERMISSION_DENIALS => PermissionDenials(options),
            DiscordPayloadKind.RATE_LIMITED => RateLimited(options),
            DiscordPayloadKind.SESSION_STALLED => SessionStalledPayload.Build(options),
            DiscordPayloadKind.DAILY_DIGEST => DailyDigestPayload.Build(options),
            _ => throw new ArgumentOutOfRangeException(nameof(command), command.Kind, "Unknown Discord payload"),
        };
    }

    // An argument that was not UTF-8 reaches .NET with U+FFFD in place of the bad bytes, which jq may replace
    // differently
    private static void RefuseReplacedArguments(DiscordCommand command)
    {
        if (command.Options.Values.Any(value => value.Contains('�', StringComparison.Ordinal)))
        {
            throw new DiscordRefusedException("an argument is not UTF-8");
        }
    }

    // Title, link, colour and six inline fields, then an Overall field only when that text is not empty
    private static JqValue WorkItem(IReadOnlyDictionary<string, string> options)
    {
        List<JqValue> fields =
        [
            Field(
                name: "Repository",
                value: Text(options: options, name: DiscordCommandParser.Repository),
                inline: true
            ),
            Field(name: "Type", value: Text(options: options, name: DiscordCommandParser.ItemType), inline: true),
            Field(name: "Priority", value: Text(options: options, name: DiscordCommandParser.Priority), inline: true),
            Field(name: "Status", value: Text(options: options, name: DiscordCommandParser.Status), inline: true),
            Field(
                name: "Sub-status",
                value: Text(options: options, name: DiscordCommandParser.Substatus),
                inline: true
            ),
            Field(name: "Progress", value: Text(options: options, name: DiscordCommandParser.Progress), inline: true),
        ];

        string overall = options[DiscordCommandParser.Overall];

        if (overall.Length > 0)
        {
            fields.Add(Field(name: "Overall", value: JqValue.FromString(overall), inline: true));
        }

        return Embed(
            Property(name: "title", value: Text(options: options, name: DiscordCommandParser.Title)),
            Property(name: "url", value: Text(options: options, name: DiscordCommandParser.Link)),
            Property(name: "color", value: Integer(options: options, name: DiscordCommandParser.Color)),
            Property(name: "fields", value: JqValue.FromArray(fields))
        );
    }

    // Title, description and the blue colour
    private static JqValue NoWork(IReadOnlyDictionary<string, string> options)
    {
        return Embed(
            Property(name: "title", value: Text(options: options, name: DiscordCommandParser.Title)),
            Property(name: "description", value: Text(options: options, name: DiscordCommandParser.Description)),
            Property(name: "color", value: JqValue.FromInteger(Blue))
        );
    }

    // Available and Minimum Required, each the number followed by GB
    private static JqValue LowDiskSpace(IReadOnlyDictionary<string, string> options)
    {
        return TitledFields(
            options: options,
            Field(
                name: "Available",
                value: Suffixed(options: options, name: DiscordCommandParser.Available, suffix: " GB"),
                inline: true
            ),
            Field(
                name: "Minimum Required",
                value: Suffixed(options: options, name: DiscordCommandParser.Minimum, suffix: " GB"),
                inline: true
            )
        );
    }

    // Duration and Baseline, each the number of seconds followed by s
    private static JqValue SlowPull(IReadOnlyDictionary<string, string> options)
    {
        return TitledFields(
            options: options,
            Field(
                name: "Duration",
                value: Suffixed(options: options, name: DiscordCommandParser.Duration, suffix: "s"),
                inline: true
            ),
            Field(
                name: "Baseline",
                value: Suffixed(options: options, name: DiscordCommandParser.Baseline, suffix: "s"),
                inline: true
            )
        );
    }

    // One Error field, not inline
    private static JqValue ItemError(IReadOnlyDictionary<string, string> options)
    {
        return LinkedFields(
            options: options,
            color: Red,
            Field(name: "Error", value: Text(options: options, name: DiscordCommandParser.Error), inline: false)
        );
    }

    // The fixed description, then the Failed step field, not inline
    private static JqValue BoardConversionFailed(IReadOnlyDictionary<string, string> options)
    {
        return Embed(
            Property(name: "title", value: Text(options: options, name: DiscordCommandParser.Title)),
            Property(name: "color", value: JqValue.FromInteger(Red)),
            Property(name: "description", value: JqValue.FromString(BoardConversionFailedText)),
            Property(
                name: "fields",
                value: JqValue.FromArray([
                    Field(
                        name: "Failed step",
                        value: Text(options: options, name: DiscordCommandParser.Step),
                        inline: false
                    ),
                ])
            )
        );
    }

    // Running commit, then the number of commits behind origin/main
    private static JqValue SelfUpdateStale(IReadOnlyDictionary<string, string> options)
    {
        return TitledFields(
            options: options,
            Field(
                name: "Running commit",
                value: Text(options: options, name: DiscordCommandParser.HeadSha),
                inline: true
            ),
            Field(
                name: "Commits behind origin/main",
                value: Suffixed(options: options, name: DiscordCommandParser.Behind, suffix: string.Empty),
                inline: true
            )
        );
    }

    // The feed address (not inline), then the number of attempts
    private static JqValue PrioritiesUnreachable(IReadOnlyDictionary<string, string> options)
    {
        return TitledFields(
            options: options,
            Field(name: "URL", value: Text(options: options, name: DiscordCommandParser.Link), inline: false),
            Field(
                name: "Attempts",
                value: Suffixed(options: options, name: DiscordCommandParser.Attempts, suffix: string.Empty),
                inline: true
            )
        );
    }

    // Repository, Type, Priority, the fixed Status Blocked, Sub-status, then Reason, not inline
    private static JqValue BlockedItem(IReadOnlyDictionary<string, string> options)
    {
        return LinkedFields(
            options: options,
            color: Red,
            Field(
                name: "Repository",
                value: Text(options: options, name: DiscordCommandParser.Repository),
                inline: true
            ),
            Field(name: "Type", value: Text(options: options, name: DiscordCommandParser.ItemType), inline: true),
            Field(name: "Priority", value: Text(options: options, name: DiscordCommandParser.Priority), inline: true),
            Field(name: "Status", value: JqValue.FromString("Blocked"), inline: true),
            Field(
                name: "Sub-status",
                value: Text(options: options, name: DiscordCommandParser.Substatus),
                inline: true
            ),
            Field(name: "Reason", value: Text(options: options, name: DiscordCommandParser.Reason), inline: false)
        );
    }

    // Title, link, the blue colour and the fixed description
    private static JqValue BlockedIssueReplanning(IReadOnlyDictionary<string, string> options)
    {
        return Embed(
            Property(name: "title", value: Text(options: options, name: DiscordCommandParser.Title)),
            Property(name: "url", value: Text(options: options, name: DiscordCommandParser.Link)),
            Property(name: "color", value: JqValue.FromInteger(Blue)),
            Property(name: "description", value: JqValue.FromString(BlockedIssueReplanningText))
        );
    }

    // Repository, then the fixed Reason, not inline
    private static JqValue PrNeedsApproval(IReadOnlyDictionary<string, string> options)
    {
        return LinkedFields(
            options: options,
            color: Gold,
            Field(
                name: "Repository",
                value: Text(options: options, name: DiscordCommandParser.Repository),
                inline: true
            ),
            Field(name: "Reason", value: JqValue.FromString(PrNeedsApprovalText), inline: false)
        );
    }

    // One Denied tool calls field, not inline
    private static JqValue PermissionDenials(IReadOnlyDictionary<string, string> options)
    {
        return LinkedFields(
            options: options,
            color: Yellow,
            Field(
                name: "Denied tool calls",
                value: Text(options: options, name: DiscordCommandParser.Summary),
                inline: false
            )
        );
    }

    // The Error field, then a Resets field only when that text is not empty
    private static JqValue RateLimited(IReadOnlyDictionary<string, string> options)
    {
        JqValue error = Field(
            name: "Error",
            value: Text(options: options, name: DiscordCommandParser.Error),
            inline: false
        );
        string reset = options[DiscordCommandParser.Reset];

        return reset.Length == 0
            ? LinkedFields(options: options, color: Yellow, error)
            : LinkedFields(
                options: options,
                color: Yellow,
                error,
                Field(name: "Resets", value: JqValue.FromString(reset), inline: true)
            );
    }

    // Title, the red alert colour and the fields
    private static JqValue TitledFields(IReadOnlyDictionary<string, string> options, params JqValue[] fields)
    {
        return Embed(
            Property(name: "title", value: Text(options: options, name: DiscordCommandParser.Title)),
            Property(name: "color", value: JqValue.FromInteger(Red)),
            Property(name: "fields", value: JqValue.FromArray(fields))
        );
    }

    // Title, link, colour and the fields
    private static JqValue LinkedFields(
        IReadOnlyDictionary<string, string> options,
        long color,
        params JqValue[] fields
    )
    {
        return Embed(
            Property(name: "title", value: Text(options: options, name: DiscordCommandParser.Title)),
            Property(name: "url", value: Text(options: options, name: DiscordCommandParser.Link)),
            Property(name: "color", value: JqValue.FromInteger(color)),
            Property(name: "fields", value: JqValue.FromArray(fields))
        );
    }

    // The one embed of the payload
    internal static JqValue Embed(params JqProperty[] properties)
    {
        return JqValue.FromObject([
            Property(name: "embeds", value: JqValue.FromArray([JqValue.FromObject(properties)])),
        ]);
    }

    // One embed field: name, value and whether it is inline
    internal static JqValue Field(string name, JqValue value, bool inline)
    {
        return JqValue.FromObject([
            Property(name: "name", value: JqValue.FromString(name)),
            Property(name: "value", value: value),
            Property(name: "inline", value: JqValue.FromBoolean(inline)),
        ]);
    }

    internal static JqProperty Property(string name, JqValue value)
    {
        return new(Name: name, Value: value);
    }

    internal static JqValue Text(IReadOnlyDictionary<string, string> options, string name)
    {
        return JqValue.FromString(options[name]);
    }

    // The --argjson number as jq interpolates it into a string, then the suffix
    private static JqValue Suffixed(IReadOnlyDictionary<string, string> options, string name, string suffix)
    {
        return JqValue.FromString(Integer(options: options, name: name).Text + suffix);
    }

    // An --argjson value: only a plain JSON integer (no sign but a leading minus, no leading zero, no -0, at most
    // MAX_DIGITS digits, no surrounding space), which jq prints as written; anything else is refused, and bash's jq
    // either prints it its own way or fails on it
    private static JqValue Integer(IReadOnlyDictionary<string, string> options, string name)
    {
        string text = options[name];
        bool negative = text.Length > 0 && text[0] == '-';
        ReadOnlySpan<char> digits = negative ? text.AsSpan(1) : text.AsSpan();

        if (!IsPlainInteger(digits: digits, negative: negative))
        {
            throw new DiscordRefusedException($"--{name} is not a plain JSON integer");
        }

        return JqValue.FromInteger(
            long.Parse(s: text, style: NumberStyles.AllowLeadingSign, provider: CultureInfo.InvariantCulture)
        );
    }

    // Digits with no leading zero, and no minus before a lone zero, which jq prints as written
    internal static bool IsPlainInteger(ReadOnlySpan<char> digits, bool negative)
    {
        if (digits.Length == 0 || digits.Length > MAX_DIGITS || !IsAsciiDigits(digits))
        {
            return false;
        }

        return digits[0] != '0' || digits.Length == 1 && !negative;
    }

    private static bool IsAsciiDigits(ReadOnlySpan<char> text)
    {
        foreach (char character in text)
        {
            if (!char.IsAsciiDigit(character))
            {
                return false;
            }
        }

        return true;
    }
}
