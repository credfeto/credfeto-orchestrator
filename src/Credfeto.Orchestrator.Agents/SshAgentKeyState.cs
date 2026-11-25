using System;
using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

// Asks the ssh-agent at a socket for its keys as ssh-add -l does: connect, send one identities request, read the
// reply, and judge it (SshIdentitiesAnswer). Nothing but that one listing is ever sent. A failed connect is
// UNREACHABLE whatever the reason, as it is for ssh-add (exit 2); any failure after it (the agent closing, a short
// reply, a reply over the size limit) is NO_KEYS, as ssh-add's "communication with agent failed" is (exit 1). There is
// no timeout: an agent that never answers keeps ssh-add waiting too.
public sealed class SshAgentKeyState : ISshAgentKeyState
{
    // A socket address holds 107 bytes of path: ssh-add cuts a longer path and connects to what is left
    private const int MAX_SOCKET_PATH_BYTES = 107;

    private static readonly byte[] Request = [0, 0, 0, 1, SshIdentitiesAnswer.RequestIdentities];

    public async ValueTask<SshKeyState> KeyStateAsync(string socket, CancellationToken cancellationToken)
    {
        CheckPath(socket);

        using Socket? agent = await ConnectAsync(socket: socket, cancellationToken: cancellationToken);

        if (agent is null)
        {
            return SshKeyState.UNREACHABLE;
        }

        byte[]? reply = await ExchangeAsync(agent: agent, cancellationToken: cancellationToken);

        return reply is null ? SshKeyState.NO_KEYS : SshIdentitiesAnswer.Judge(reply);
    }

    // An empty path, a path that was not UTF-8 on the command line, one that names an abstract socket in .NET, and one
    // ssh-add would cut short are left to ssh-add
    private static void CheckPath(string socket)
    {
        if (
            socket.Length == 0
            || socket[0] is '@' or '\0'
            || socket.Contains('�', StringComparison.Ordinal)
            || Encoding.UTF8.GetByteCount(socket) > MAX_SOCKET_PATH_BYTES
        )
        {
            throw new AgentRefusedException("the socket path is not one the tool connects to as ssh-add would");
        }
    }

    private static async ValueTask<Socket?> ConnectAsync(string socket, CancellationToken cancellationToken)
    {
        Socket? agent = null;

        try
        {
            agent = new(
                addressFamily: AddressFamily.Unix,
                socketType: SocketType.Stream,
                protocolType: ProtocolType.Unspecified
            );
            await agent.ConnectAsync(
                remoteEP: new UnixDomainSocketEndPoint(socket),
                cancellationToken: cancellationToken
            );

            Socket connected = agent;
            agent = null;

            return connected;
        }
        catch (SocketException)
        {
            return null;
        }
        finally
        {
            agent?.Dispose();
        }
    }

    private static async ValueTask<byte[]?> ExchangeAsync(Socket agent, CancellationToken cancellationToken)
    {
        try
        {
            await SendAsync(agent: agent, cancellationToken: cancellationToken);

            byte[] header = new byte[sizeof(uint)];

            if (!await ReceiveAsync(agent: agent, buffer: header, cancellationToken: cancellationToken))
            {
                return null;
            }

            uint length = BinaryPrimitives.ReadUInt32BigEndian(header);

            if (length > SshIdentitiesAnswer.MaxReplyLength)
            {
                return null;
            }

            byte[] reply = new byte[length];

            return await ReceiveAsync(agent: agent, buffer: reply, cancellationToken: cancellationToken) ? reply : null;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    private static async ValueTask SendAsync(Socket agent, CancellationToken cancellationToken)
    {
        int sent = 0;

        while (sent < Request.Length)
        {
            sent += await agent.SendAsync(
                buffer: Request.AsMemory(sent),
                socketFlags: SocketFlags.None,
                cancellationToken: cancellationToken
            );
        }
    }

    // Fills the buffer, or returns false when the agent closes the connection first
    private static async ValueTask<bool> ReceiveAsync(Socket agent, byte[] buffer, CancellationToken cancellationToken)
    {
        int received = 0;

        while (received < buffer.Length)
        {
            int read = await agent.ReceiveAsync(
                buffer: buffer.AsMemory(received),
                socketFlags: SocketFlags.None,
                cancellationToken: cancellationToken
            );

            if (read == 0)
            {
                return false;
            }

            received += read;
        }

        return true;
    }
}
