using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class DiscordCommandParserTests : TestBase
{
    [Theory]
    [InlineData("discord|payload|host-health|--title|t|--message|m", DiscordPayloadKind.HOST_HEALTH, "message", "m")]
    [InlineData("discord|payload|host-health|--message||--title|t", DiscordPayloadKind.HOST_HEALTH, "message", "")]
    [InlineData(
        "discord|payload|no-work|--title|--title|--description|d",
        DiscordPayloadKind.NO_WORK,
        "title",
        "--title"
    )]
    [InlineData(
        "discord|payload|self-update-stale|--title|t|--head-sha|abc|--behind|x",
        DiscordPayloadKind.SELF_UPDATE_STALE,
        "behind",
        "x"
    )]
    [InlineData(
        "discord|payload|rate-limited|--title|t|--url|u|--error|e|--reset|r",
        DiscordPayloadKind.RATE_LIMITED,
        "reset",
        "r"
    )]
    public static void EachKindTakesItsOptions(string args, DiscordPayloadKind kind, string option, string value)
    {
        DiscordCommand? command = DiscordCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.NotNull(command);
        Assert.Equal(expected: kind, actual: command.Kind);
        Assert.Equal(expected: value, actual: command.Options[option]);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("discord", "expected: discord payload <kind> --<option> <value> ...")]
    [InlineData("discord|payload", "expected: discord payload <kind> --<option> <value> ...")]
    [InlineData("discord|send|host-health", "expected: discord payload <kind> --<option> <value> ...")]
    [InlineData("state|payload|host-health", "expected: discord payload <kind> --<option> <value> ...")]
    [InlineData("discord|payload|session-stalled", "unknown discord payload 'session-stalled'")]
    [InlineData("discord|payload|host-health", "discord payload host-health needs --title <value> --message <value>")]
    [InlineData("discord|payload|host-health|--title|t", "discord payload host-health needs --title <value>")]
    [InlineData("discord|payload|host-health|--title|t|--message", "discord payload host-health needs --title")]
    [InlineData("discord|payload|host-health|--title|t|--title|u", "discord payload host-health needs --title")]
    [InlineData("discord|payload|host-health|--title|t|--url|u", "discord payload host-health needs --title")]
    [InlineData("discord|payload|host-health|--title|t|message|m", "discord payload host-health needs --title")]
    [InlineData("discord|payload|host-health|--title|t|--message|m|--url|u", "discord payload host-health needs")]
    public static void AnythingElseIsAUsageError(string args, string expected)
    {
        DiscordCommand? command = DiscordCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.StartsWith(expectedStartString: expected, actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("discord|payload", true)]
    [InlineData("discord", true)]
    [InlineData("state|rate-limit", false)]
    [InlineData("", false)]
    public static void TheVerbIsDiscord(string args, bool expected)
    {
        Assert.Equal(expected: expected, actual: DiscordCommandParser.IsVerb(args.Length == 0 ? [] : args.Split('|')));
    }
}
