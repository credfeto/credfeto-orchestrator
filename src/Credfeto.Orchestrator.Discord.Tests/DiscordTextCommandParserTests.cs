using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discord.Tests;

public sealed class DiscordTextCommandParserTests : TestBase
{
    [Theory]
    [InlineData(
        "discord|item-status|--type|Issue|--id|1|--repo|o/r|--reason|r",
        DiscordTextKind.ITEM_STATUS,
        "id",
        "1"
    )]
    [InlineData("discord|item-status|--reason||--repo|o/r|--id|1|--type|t", DiscordTextKind.ITEM_STATUS, "reason", "")]
    [InlineData(
        "discord|no-work-breakdown|--default-repo|o/r|--length-unit|bytes",
        DiscordTextKind.NO_WORK_BREAKDOWN,
        "length-unit",
        "bytes"
    )]
    [InlineData("discord|truncate|--max-length|900", DiscordTextKind.TRUNCATE, "max-length", "900")]
    public static void EachCommandTakesItsOptions(string args, DiscordTextKind kind, string option, string value)
    {
        DiscordTextCommand? command = DiscordTextCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.NotNull(command);
        Assert.Equal(expected: kind, actual: command.Kind);
        Assert.Equal(expected: value, actual: command.Options[option]);
        Assert.Equal(expected: kind != DiscordTextKind.ITEM_STATUS, actual: command.ReadsInput);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public static void TheItemStatusLogTakesNoOptions()
    {
        DiscordTextCommand? command = DiscordTextCommandParser.Parse(
            args: ["discord", "item-status-log"],
            error: out string error
        );

        Assert.NotNull(command);
        Assert.Equal(expected: DiscordTextKind.ITEM_STATUS_LOG, actual: command.Kind);
        Assert.Empty(command.Options);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData(
        "discord|item-status-log|--extra|x",
        "discord item-status-log needs no options, each once, and nothing else"
    )]
    [InlineData("discord|truncate", "discord truncate needs --max-length <value>, each once, and nothing else")]
    [InlineData(
        "discord|truncate|--max-length|1|--max-length|2",
        "discord truncate needs --max-length <value>, each once, and nothing else"
    )]
    [InlineData(
        "discord|no-work-breakdown|--default-repo|o/r|--length|bytes",
        "discord no-work-breakdown needs --default-repo <value> --length-unit <value>, each once, and nothing else"
    )]
    [InlineData(
        "discord|payload|no-work",
        "expected: discord item-status|item-status-log|no-work-breakdown|truncate --<option> <value> ..."
    )]
    public static void AnythingElseIsAUsageError(string args, string expected)
    {
        DiscordTextCommand? command = DiscordTextCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.Equal(expected: expected, actual: error);
    }

    [Theory]
    [InlineData("discord|truncate", true)]
    [InlineData("discord|item-status", true)]
    [InlineData("discord|payload", false)]
    [InlineData("discord", false)]
    [InlineData("state|truncate", false)]
    public static void OnlyTheTextCommandsAreTextCommands(string args, bool expected)
    {
        Assert.Equal(expected: expected, actual: DiscordTextCommandParser.IsTextCommand(args.Split('|')));
    }
}
