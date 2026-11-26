using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

// credfeto-orchestrator agent ...: answers a read-only ssh-agent query as the lib/podman function's ssh-add would,
// printing nothing and exiting with the status the function returns (4 standing for ssh-add's 2)
public sealed class AgentCommandRunner
{
    public const int NoKeys = 1;

    public const int Usage = 2;

    // The query cannot be answered exactly as bash would answer it, so lib/podman answers it in bash
    public const int Refused = 3;

    // Nothing could be connected to at the socket: ssh-add's exit 2, which is this tool's usage error
    public const int Unreachable = 4;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator agent ssh-key-state --socket <path>

        ssh-key-state asks the ssh-agent at the socket for its keys, sending only the identities request ssh-add -l
        sends, and exits as ssh_agent_key_state returns: 0 the agent holds a key ssh-add would list; 1 it holds none,
        or its reply is an error or one ssh-add rejects; 4 nothing could be connected to (ssh-add's 2). It prints
        nothing.

        Exit codes: 0, 1 or 4 the answer; 2 a usage error; 3 the query cannot be answered exactly as ssh-add would (a
        key type other than ssh-ed25519 and ssh-rsa, an RSA key outside the form ssh-keygen writes, or a socket path
        that is empty, not UTF-8, starts with @ or is too long for a socket address), so lib/podman runs ssh-add.
        """;

    private readonly ISshAgentKeyState _keys;

    public AgentCommandRunner(ISshAgentKeyState keys)
    {
        this._keys = keys;
    }

    public static AgentCommandRunner CreateDefault()
    {
        return new(new SshAgentKeyState());
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        AgentCommand? command = AgentCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
            await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return Usage;
        }

        try
        {
            SshKeyState state = await this._keys.KeyStateAsync(
                socket: command.Socket,
                cancellationToken: cancellationToken
            );

            return state switch
            {
                SshKeyState.KEYS => 0,
                SshKeyState.NO_KEYS => NoKeys,
                _ => Unreachable,
            };
        }
        catch (AgentRefusedException exception)
        {
            await error.WriteLineAsync($"{PROGRAM}: agent: {exception.Message}".AsMemory(), cancellationToken);

            return Refused;
        }
        catch (OperationCanceledException)
        {
            return Cancelled;
        }
    }
}
