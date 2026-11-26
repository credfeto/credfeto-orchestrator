using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Credfeto.Orchestrator.Discord;

// discord payload <kind> --<option> <value> ...: every option the kind takes, each once, in any order; a value may be
// empty, as the lib/discord builder's argument may be
public static class DiscordCommandParser
{
    public const string Verb = "discord";
    public const string Payload = "payload";

    public const string Color = "color";
    public const string Title = "title";
    public const string Link = "url";
    public const string Repository = "repository";
    public const string ItemType = "type";
    public const string Priority = "priority";
    public const string Status = "status";
    public const string Substatus = "substatus";
    public const string Progress = "progress";
    public const string Overall = "overall";
    public const string Description = "description";
    public const string Available = "available";
    public const string Minimum = "minimum";
    public const string Message = "message";
    public const string Duration = "duration";
    public const string Baseline = "baseline";
    public const string Error = "error";
    public const string Step = "step";
    public const string HeadSha = "head-sha";
    public const string Behind = "behind";
    public const string Attempts = "attempts";
    public const string Reason = "reason";
    public const string Summary = "summary";
    public const string Reset = "reset";
    public const string Item = "item";
    public const string Count = "count";
    public const string Commands = "commands";
    public const string Owner = "owner";
    public const string Day = "day";
    public const string Previous = "previous";

    private const string OPTION_PREFIX = "--";

    private static readonly IReadOnlyDictionary<string, Definition> Kinds = new Dictionary<string, Definition>(
        StringComparer.Ordinal
    )
    {
        ["work-item"] = new(
            DiscordPayloadKind.WORK_ITEM,
            [Color, Title, Link, Repository, ItemType, Priority, Status, Substatus, Progress, Overall]
        ),
        ["no-work"] = new(DiscordPayloadKind.NO_WORK, [Title, Description]),
        ["low-disk-space"] = new(DiscordPayloadKind.LOW_DISK_SPACE, [Title, Available, Minimum]),
        ["host-health"] = new(DiscordPayloadKind.HOST_HEALTH, [Title, Message]),
        ["slow-pull"] = new(DiscordPayloadKind.SLOW_PULL, [Title, Duration, Baseline]),
        ["item-error"] = new(DiscordPayloadKind.ITEM_ERROR, [Title, Link, Error]),
        ["board-conversion-failed"] = new(DiscordPayloadKind.BOARD_CONVERSION_FAILED, [Title, Step]),
        ["self-update-stale"] = new(DiscordPayloadKind.SELF_UPDATE_STALE, [Title, HeadSha, Behind]),
        ["priorities-unreachable"] = new(DiscordPayloadKind.PRIORITIES_UNREACHABLE, [Title, Link, Attempts]),
        ["blocked-item"] = new(
            DiscordPayloadKind.BLOCKED_ITEM,
            [Title, Link, Repository, ItemType, Priority, Substatus, Reason]
        ),
        ["blocked-issue-replanning"] = new(DiscordPayloadKind.BLOCKED_ISSUE_REPLANNING, [Title, Link]),
        ["pr-needs-approval"] = new(DiscordPayloadKind.PR_NEEDS_APPROVAL, [Title, Link, Repository]),
        ["permission-denials"] = new(DiscordPayloadKind.PERMISSION_DENIALS, [Title, Link, Summary]),
        ["rate-limited"] = new(DiscordPayloadKind.RATE_LIMITED, [Title, Link, Error, Reset]),
        ["session-stalled"] = new(
            DiscordPayloadKind.SESSION_STALLED,
            [Repository, Item, Link, Count, Commands, Message]
        ),
        ["daily-digest"] = new(DiscordPayloadKind.DAILY_DIGEST, [Owner, Day, Summary, Previous]),
    };

    public static string KindNames => string.Join(separator: ", ", values: Kinds.Keys);

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    public static DiscordCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 3 || !IsVerb(args) || !StringComparer.Ordinal.Equals(x: args[1], y: Payload))
        {
            error = "expected: discord payload <kind> --<option> <value> ..., the kind one of " + KindNames;

            return null;
        }

        if (!Kinds.TryGetValue(key: args[2], value: out Definition? definition))
        {
            error = $"unknown discord payload '{args[2]}': expected one of {KindNames}";

            return null;
        }

        Dictionary<string, string>? options = ParseOptions(args: args, definition: definition);

        if (options is null)
        {
            error = $"discord payload {args[2]} needs {Describe(definition)}, each once, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Kind: definition.Kind, Options: options);
    }

    private static Dictionary<string, string>? ParseOptions(IReadOnlyList<string> args, Definition definition)
    {
        if (args.Count != 3 + definition.Options.Count * 2)
        {
            return null;
        }

        Dictionary<string, string> options = [with(StringComparer.Ordinal)];

        for (int index = 3; index < args.Count; index += 2)
        {
            string name = args[index];

            if (
                !name.StartsWith(value: OPTION_PREFIX, comparisonType: StringComparison.Ordinal)
                || !definition.Options.Contains(value: name[OPTION_PREFIX.Length..], comparer: StringComparer.Ordinal)
                || !options.TryAdd(key: name[OPTION_PREFIX.Length..], value: args[index + 1])
            )
            {
                return null;
            }
        }

        return options;
    }

    private static string Describe(Definition definition)
    {
        return string.Join(separator: ' ', values: definition.Options.Select(option => $"--{option} <value>"));
    }

    [DebuggerDisplay("Kind={Kind}")]
    private sealed record Definition(DiscordPayloadKind Kind, IReadOnlyList<string> Options);
}
