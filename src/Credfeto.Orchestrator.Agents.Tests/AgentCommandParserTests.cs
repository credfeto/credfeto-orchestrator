using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class AgentCommandParserTests : TestBase
{
    [Theory]
    [InlineData("agent|ssh-key-state|--socket|/run/agent.sock", "/run/agent.sock")]
    [InlineData("agent|ssh-key-state|--socket|--socket", "--socket")]
    [InlineData("agent|ssh-key-state|--socket|", "")]
    public static void TheQueryTakesItsSocket(string args, string socket)
    {
        AgentCommand? command = AgentCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Equal(expected: new AgentCommand(Query: AgentQuery.SSH_KEY_STATE, Socket: socket), actual: command);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("agent|stop-ssh-agent|--socket|/run/agent.sock|--user|me", "/run/agent.sock", "me")]
    [InlineData("agent|stop-ssh-agent|--socket|--user|--user|--socket", "--user", "--socket")]
    [InlineData("agent|stop-ssh-agent|--socket||--user|", "", "")]
    public static void TheStopTakesItsSocketAndUser(string args, string socket, string user)
    {
        AgentCommand? command = AgentCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Equal(
            expected: new AgentCommand(Query: AgentQuery.STOP_SSH_AGENT, Socket: socket, User: user),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("agent", "expected: agent ssh-key-state --socket <path>")]
    [InlineData("git|head-sha", "expected: agent ssh-key-state --socket <path>")]
    [InlineData("agent|ssh-add|--socket|s", "unknown agent query 'ssh-add': expected ssh-key-state or stop-ssh-agent")]
    [InlineData("agent|ssh-key-state", "agent ssh-key-state needs --socket <path>, and nothing else")]
    [InlineData("agent|ssh-key-state|--socket", "agent ssh-key-state needs --socket <path>, and nothing else")]
    [InlineData("agent|ssh-key-state|--path|s", "agent ssh-key-state needs --socket <path>, and nothing else")]
    [InlineData("agent|ssh-key-state|--socket|s|--socket|t", "agent ssh-key-state needs --socket <path>")]
    [InlineData("agent|ssh-key-state|--socket|s|--user|u", "agent ssh-key-state needs --socket <path>")]
    [InlineData("agent|stop-ssh-agent", "agent stop-ssh-agent needs --socket <path> --user <name>, and nothing else")]
    [InlineData("agent|stop-ssh-agent|--socket|s", "agent stop-ssh-agent needs --socket <path> --user <name>")]
    [InlineData("agent|stop-ssh-agent|--user|u|--socket|s", "agent stop-ssh-agent needs --socket <path> --user <name>")]
    [InlineData("agent|stop-ssh-agent|--socket|s|--user|u|x", "agent stop-ssh-agent needs --socket <path>")]
    public static void AnythingElseIsAUsageError(string args, string expected)
    {
        AgentCommand? command = AgentCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.StartsWith(expectedStartString: expected, actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("agent|ssh-key-state", true)]
    [InlineData("agent", true)]
    [InlineData("git|head-sha", false)]
    [InlineData("", false)]
    public static void TheVerbIsAgent(string args, bool expected)
    {
        Assert.Equal(expected: expected, actual: AgentCommandParser.IsVerb(args.Length == 0 ? [] : args.Split('|')));
    }
}
