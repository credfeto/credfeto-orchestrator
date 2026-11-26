using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Agents;

// agent ssh-key-state --socket <path>
public static class AgentCommandParser
{
    public const string Verb = "agent";

    private const string SOCKET = "--socket";

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    public static AgentCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !IsVerb(args))
        {
            error = "expected: agent ssh-key-state --socket <path>";

            return null;
        }

        if (!StringComparer.Ordinal.Equals(x: args[1], y: "ssh-key-state"))
        {
            error = $"unknown agent query '{args[1]}': expected ssh-key-state";

            return null;
        }

        if (args.Count != 4 || !StringComparer.Ordinal.Equals(x: args[2], y: SOCKET))
        {
            error = $"agent {args[1]} needs {SOCKET} <path>, and nothing else";

            return null;
        }

        error = string.Empty;

        return new(Query: AgentQuery.SSH_KEY_STATE, Socket: args[3]);
    }
}
