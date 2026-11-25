using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents.Tests;

// An ssh-agent stand-in on a Unix socket: while a client runs, for every connection it reads the 5-byte request,
// records it, answers with the scripted bytes (length header included) and closes, as test/oneshot-agents-parity.bats's
// python3 agent does
internal sealed class FakeSshAgent : IDisposable
{
    private const int REQUEST_BYTES = 5;

    private readonly Socket _listener;
    private readonly byte[] _reply;

    private FakeSshAgent(string path, byte[] reply)
    {
        this.Path = path;
        this._reply = reply;
        this._listener = new(
            addressFamily: AddressFamily.Unix,
            socketType: SocketType.Stream,
            protocolType: ProtocolType.Unspecified
        );
        this._listener.Bind(new UnixDomainSocketEndPoint(path));
        this._listener.Listen(8);
    }

    public string Path { get; }

    public ConcurrentQueue<string> Requests { get; } = new();

    public static FakeSshAgent Start(string directory, byte[] reply)
    {
        return new(path: System.IO.Path.Combine(path1: directory, path2: "agent.sock"), reply: reply);
    }

    public void Dispose()
    {
        this._listener.Dispose();
    }

    // Serves connections while the client runs, then stops
    public async Task<T> WhileServingAsync<T>(Func<Task<T>> client, CancellationToken cancellationToken)
    {
        using CancellationTokenSource stop = new();
        Task serving = this.ServeAsync(stop.Token);

        try
        {
            return await client();
        }
        finally
        {
            await stop.CancelAsync();
            await serving;
        }
    }

    private async Task ServeAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                using Socket connection = await this._listener.AcceptAsync(cancellationToken);
                await this.AnswerAsync(connection: connection, cancellationToken: cancellationToken);
            }
        }
        catch (OperationCanceledException)
        {
            // The client is done
        }
    }

    private async Task AnswerAsync(Socket connection, CancellationToken cancellationToken)
    {
        byte[] request = new byte[REQUEST_BYTES];
        int received = 0;

        try
        {
            while (received < REQUEST_BYTES)
            {
                int read = await connection.ReceiveAsync(
                    buffer: request.AsMemory(received),
                    socketFlags: SocketFlags.None,
                    cancellationToken: cancellationToken
                );

                if (read == 0)
                {
                    break;
                }

                received += read;
            }

            this.Requests.Enqueue(Convert.ToHexStringLower(request.AsSpan(start: 0, length: received)));
            await connection.SendAsync(
                buffer: this._reply,
                socketFlags: SocketFlags.None,
                cancellationToken: cancellationToken
            );
        }
        catch (SocketException)
        {
            // The client went before the whole reply was sent
        }
        catch (IOException)
        {
            // The client went before the whole reply was sent
        }
    }
}
