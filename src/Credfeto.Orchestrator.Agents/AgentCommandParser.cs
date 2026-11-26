using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Agents;

// agent ssh-key-state --socket <path>
// agent stop-ssh-agent --socket <path> --user <name>
public static class AgentCommandParser
{
    public const string Verb = "agent";

    private const string SOCKET = "--socket";

    private const string USER = "--user";

    private const string KEY_STATE = "ssh-key-state";

    private const string STOP = "stop-ssh-agent";

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    public static AgentCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !IsVerb(args))
        {
            error = $"expected: agent {KEY_STATE} {SOCKET} <path>, or agent {STOP} {SOCKET} <path> {USER} <name>";

            return null;
        }

        if (StringComparer.Ordinal.Equals(x: args[1], y: KEY_STATE))
        {
            return ParseKeyState(args: args, error: out error);
        }

        if (StringComparer.Ordinal.Equals(x: args[1], y: STOP))
        {
            return ParseStop(args: args, error: out error);
        }

        error = $"unknown agent query '{args[1]}': expected {KEY_STATE} or {STOP}";

        return null;
    }

    private static AgentCommand? ParseKeyState(IReadOnlyList<string> args, out string error)
    {
        if (args.Count != 4 || !StringComparer.Ordinal.Equals(x: args[2], y: SOCKET))
        {
            error = $"agent {KEY_STATE} needs {SOCKET} <path>, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Query: AgentQuery.SSH_KEY_STATE, Socket: args[3]);
    }

    private static AgentCommand? ParseStop(IReadOnlyList<string> args, out string error)
    {
        if (
            args.Count != 6
            || !StringComparer.Ordinal.Equals(x: args[2], y: SOCKET)
            || !StringComparer.Ordinal.Equals(x: args[4], y: USER)
        )
        {
            error = $"agent {STOP} needs {SOCKET} <path> {USER} <name>, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Query: AgentQuery.STOP_SSH_AGENT, Socket: args[3], User: args[5]);
    }
}
