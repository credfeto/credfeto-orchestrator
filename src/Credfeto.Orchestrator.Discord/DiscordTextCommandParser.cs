using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Credfeto.Orchestrator.Discord;

// discord item-status|item-status-log|no-work-breakdown|truncate --<option> <value> ...: every option the command
// takes, each once, in any order; a value may be empty, as the lib/discord function's argument may be
public static class DiscordTextCommandParser
{
    public const string Id = "id";
    public const string Repo = "repo";
    public const string DefaultRepo = "default-repo";
    public const string LengthUnit = "length-unit";
    public const string MaxLength = "max-length";

    private static readonly IReadOnlyDictionary<string, Definition> Commands = new Dictionary<string, Definition>(
        StringComparer.Ordinal
    )
    {
        ["item-status"] = new(
            DiscordTextKind.ITEM_STATUS,
            [DiscordCommandParser.ItemType, Id, Repo, DiscordCommandParser.Reason]
        ),
        ["item-status-log"] = new(DiscordTextKind.ITEM_STATUS_LOG, []),
        ["no-work-breakdown"] = new(DiscordTextKind.NO_WORK_BREAKDOWN, [DefaultRepo, LengthUnit]),
        ["truncate"] = new(DiscordTextKind.TRUNCATE, [MaxLength]),
    };

    // Every text command; the tool's --capabilities lists them
    public static IReadOnlyList<string> Names { get; } = [.. Commands.Keys.Order(StringComparer.Ordinal)];

    // Whether args name one of these commands, so the runner parses them here rather than as a payload
    public static bool IsTextCommand(IReadOnlyList<string> args)
    {
        return DiscordCommandParser.IsVerb(args) && args.Count > 1 && Commands.ContainsKey(args[1]);
    }

    public static DiscordTextCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (!IsTextCommand(args))
        {
            error =
                "expected: discord " + string.Join(separator: '|', values: Commands.Keys) + " --<option> <value> ...";

            return null;
        }

        Definition definition = Commands[args[1]];
        Dictionary<string, string>? options = DiscordCommandParser.ParseOptions(
            args: args,
            start: 2,
            names: definition.Options
        );

        if (options is null)
        {
            error = $"discord {args[1]} needs {Describe(definition)}, each once, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Kind: definition.Kind, Options: options);
    }

    private static string Describe(Definition definition)
    {
        return definition.Options.Count == 0
            ? "no options"
            : string.Join(separator: ' ', values: definition.Options.Select(option => $"--{option} <value>"));
    }

    [DebuggerDisplay("Kind={Kind}")]
    private sealed record Definition(DiscordTextKind Kind, IReadOnlyList<string> Options);
}
