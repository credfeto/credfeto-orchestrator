using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

public sealed class StateCommandParserTests : TestBase
{
    [Theory]
    [InlineData(
        "state|infra-failures|--session-dir|/s|--type|PullRequest|--id|7",
        StateQuery.INFRA_FAILURES,
        "id",
        "7"
    )]
    [InlineData("state|invocations|--id|9|--type|Issue|--session-dir|/s", StateQuery.INVOCATIONS, "type", "Issue")]
    [InlineData("state|env-unblock-attempts|--session-dir||--id|7", StateQuery.ENV_UNBLOCK_ATTEMPTS, "session-dir", "")]
    [InlineData(
        "state|marker|--session-dir|/s|--type|Issue|--id|5|--kind|plan-block",
        StateQuery.MARKER,
        "kind",
        "plan-block"
    )]
    [InlineData("state|last-diagnostic|--session-dir|/s|--type|a b|--id|7", StateQuery.LAST_DIAGNOSTIC, "type", "a b")]
    [InlineData("state|precheck-result|--session-dir|/s|--key|main|--sha|", StateQuery.PRECHECK_RESULT, "sha", "")]
    [InlineData(
        "state|pull-duration-baseline|--state-dir|/t|--owner|o|--min-samples|abc",
        StateQuery.PULL_DURATION_BASELINE,
        "min-samples",
        "abc"
    )]
    [InlineData("state|rate-limit|--state-dir|/t|--owner|--owner", StateQuery.RATE_LIMIT, "owner", "--owner")]
    [InlineData("state|session-denials-summary|--file|/t/f", StateQuery.SESSION_DENIALS_SUMMARY, "file", "/t/f")]
    public static void EachQueryTakesItsOptions(string args, StateQuery query, string option, string value)
    {
        StateCommand? command = StateCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.NotNull(command);
        Assert.Equal(expected: query, actual: command.Query);
        Assert.Equal(expected: value, actual: command.Option(option));
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("state", "expected: state <query> --<option> <value> ...")]
    [InlineData("git|head-sha", "expected: state <query> --<option> <value> ...")]
    [InlineData("state|save-rate-limit|--owner|o", "unknown state query 'save-rate-limit'")]
    [InlineData("state|rate-limit", "state rate-limit needs --state-dir <value> --owner <value>, each once")]
    [InlineData("state|rate-limit|--state-dir|/t", "state rate-limit needs --state-dir <value> --owner <value>")]
    [InlineData("state|rate-limit|--state-dir|/t|--owner", "state rate-limit needs --state-dir <value>")]
    [InlineData("state|rate-limit|--state-dir|/t|--state-dir|/u", "state rate-limit needs --state-dir <value>")]
    [InlineData("state|rate-limit|--state-dir|/t|--id|7", "state rate-limit needs --state-dir <value>")]
    [InlineData("state|rate-limit|--state-dir|/t|owner|o", "state rate-limit needs --state-dir <value>")]
    [InlineData("state|rate-limit|--state-dir|/t|--owner|o|--id|7", "state rate-limit needs --state-dir <value>")]
    [InlineData(
        "state|invocations|--session-dir|/s|--type|Workflow|--id|7",
        "state invocations --type must be PullRequest or Issue"
    )]
    [InlineData(
        "state|marker|--session-dir|/s|--type|Issue|--id|7|--kind|blocked",
        "state marker --kind must be one of plan-block, blocked-replan, background-stall"
    )]
    public static void AnythingElseIsAUsageError(string args, string expected)
    {
        StateCommand? command = StateCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.StartsWith(expectedStartString: expected, actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("state|rate-limit", true)]
    [InlineData("state", true)]
    [InlineData("podman|image-sha", false)]
    [InlineData("", false)]
    public static void TheVerbIsState(string args, bool expected)
    {
        Assert.Equal(expected: expected, actual: StateCommandParser.IsVerb(args.Length == 0 ? [] : args.Split('|')));
    }
}
