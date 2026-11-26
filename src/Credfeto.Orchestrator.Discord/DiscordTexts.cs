using System;
using System.Collections.Generic;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// The lib/discord text functions: what each prints, byte for byte, given what lib/discord hands the tool
public static class DiscordTexts
{
    public static string Build(DiscordTextCommand command, ReadOnlySpan<byte> input)
    {
        foreach (string value in command.Options.Values)
        {
            DiscordTextInput.RefuseReplaced(value);
        }

        IReadOnlyDictionary<string, string> options = command.Options;

        return command.Kind switch
        {
            DiscordTextKind.ITEM_STATUS => ItemStatus(options),
            DiscordTextKind.ITEM_STATUS_LOG => ItemStatusLog(DiscordTextInput.Json(DiscordTextInput.Text(input))),
            DiscordTextKind.NO_WORK_BREAKDOWN => NoWorkBreakdown.Build(
                input: DiscordTextInput.Json(DiscordTextInput.Text(input)),
                defaultRepo: options[DiscordTextCommandParser.DefaultRepo],
                unit: NoWorkBreakdown.ParseUnit(options[DiscordTextCommandParser.LengthUnit])
            ),
            DiscordTextKind.TRUNCATE => DisplayTruncation.Truncate(
                text: DiscordTextInput.Text(input),
                maxLength: options[DiscordTextCommandParser.MaxLength]
            ),
            _ => throw new ArgumentOutOfRangeException(nameof(command), command.Kind, "Unknown Discord text command"),
        };
    }

    // record_item_status: jq -cn of {type,id,repo,reason}, each an --arg string, then jq's newline
    private static string ItemStatus(IReadOnlyDictionary<string, string> options)
    {
        JqValue status = JqValue.FromObject([
            Text(options: options, name: DiscordCommandParser.ItemType, key: "type"),
            Text(options: options, name: DiscordTextCommandParser.Id, key: "id"),
            Text(options: options, name: DiscordTextCommandParser.Repo, key: "repo"),
            Text(options: options, name: DiscordCommandParser.Reason, key: "reason"),
        ]);

        return JqFormatter.ToJson(status) + "\n";
    }

    // serialize_item_status_log: jq -s -c . of every entry, then jq's newline
    private static string ItemStatusLog(JqInput input)
    {
        return JqFormatter.ToJson(JqValue.FromArray([.. input.Values])) + "\n";
    }

    private static JqProperty Text(IReadOnlyDictionary<string, string> options, string name, string key)
    {
        return new(Name: key, Value: JqValue.FromString(options[name]));
    }
}
