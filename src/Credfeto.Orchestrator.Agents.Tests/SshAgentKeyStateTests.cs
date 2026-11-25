using System;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class SshAgentKeyStateTests : TestBase
{
    [Fact]
    public async Task TheAgentIsSentOnlyTheIdentitiesRequestAsync()
    {
        using TestDirectory directory = new();
        using FakeSshAgent agent = FakeSshAgent.Start(
            directory: directory.Path,
            reply: Framed(SshWire.Answer(1, SshWire.Entry(SshWire.Ed25519())))
        );

        SshKeyState state = await AskAsync(agent: agent, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: SshKeyState.KEYS, actual: state);
        Assert.Equal(expected: ["000000010b"], actual: agent.Requests.ToArray());
    }

    [Theory]
    [InlineData("")]
    [InlineData("0000")]
    [InlineData("00000000")]
    [InlineData("0000000a0c0000")]
    [InlineData("00040001")]
    [InlineData("ffffffff")]
    [InlineData("0000000100")]
    public async Task AnAgentThatClosesEarlyOrSendsTooMuchHasNoKeysAsync(string reply)
    {
        using TestDirectory directory = new();
        using FakeSshAgent agent = FakeSshAgent.Start(directory: directory.Path, reply: Convert.FromHexString(reply));

        SshKeyState state = await AskAsync(agent: agent, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: SshKeyState.NO_KEYS, actual: state);
    }

    [Fact]
    public async Task AReplyOfExactlyTheLimitIsReadAsync()
    {
        using TestDirectory directory = new();
        byte[] answer = SshWire.Answer(1, SshWire.Entry(SshWire.Ed25519()));
        byte[] reply = [.. answer, .. new byte[(int)SshIdentitiesAnswer.MaxReplyLength - answer.Length]];
        using FakeSshAgent agent = FakeSshAgent.Start(directory: directory.Path, reply: Framed(reply));

        SshKeyState state = await AskAsync(agent: agent, cancellationToken: this.CancellationToken());

        Assert.Equal(expected: SshKeyState.KEYS, actual: state);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("file")]
    [InlineData("directory")]
    [InlineData("stale")]
    public async Task NothingToConnectToIsUnreachableAsync(string kind)
    {
        using TestDirectory directory = new();
        string socket = Path.Combine(path1: directory.Path, path2: "agent.sock");

        switch (kind)
        {
            case "file":
                await File.WriteAllTextAsync(
                    path: socket,
                    contents: string.Empty,
                    cancellationToken: this.CancellationToken()
                );

                break;
            case "directory":
                Directory.CreateDirectory(socket);

                break;
            case "stale":
                using (
                    Socket bound = new(
                        addressFamily: AddressFamily.Unix,
                        socketType: SocketType.Stream,
                        protocolType: ProtocolType.Unspecified
                    )
                )
                {
                    bound.Bind(new UnixDomainSocketEndPoint(socket));
                }

                break;
        }

        SshKeyState state = await new SshAgentKeyState().KeyStateAsync(
            socket: socket,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: SshKeyState.UNREACHABLE, actual: state);
    }

    [Theory]
    [InlineData("")]
    [InlineData("@abstract")]
    [InlineData("/tmp/not-utf8-�")]
    public Task APathItLeavesToSshAddIsRefusedAsync(string socket)
    {
        return Assert.ThrowsAsync<AgentRefusedException>(() =>
            new SshAgentKeyState().KeyStateAsync(socket: socket, cancellationToken: this.CancellationToken()).AsTask()
        );
    }

    [Fact]
    public Task APathLongerThanASocketAddressIsRefusedAsync()
    {
        string socket = "/tmp/" + new string(c: 'x', count: 103);

        return Assert.ThrowsAsync<AgentRefusedException>(() =>
            new SshAgentKeyState().KeyStateAsync(socket: socket, cancellationToken: this.CancellationToken()).AsTask()
        );
    }

    [Fact]
    public async Task APathOfExactlyTheLimitIsTriedAsync()
    {
        string socket = "/tmp/" + new string(c: 'x', count: 102);

        SshKeyState state = await new SshAgentKeyState().KeyStateAsync(
            socket: socket,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: SshKeyState.UNREACHABLE, actual: state);
    }

    [Fact]
    public async Task ACancelledQueryStopsAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();
        using TestDirectory directory = new();
        using FakeSshAgent agent = FakeSshAgent.Start(directory: directory.Path, reply: []);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            AskAsync(agent: agent, cancellationToken: cancelled.Token)
        );
    }

    private static Task<SshKeyState> AskAsync(FakeSshAgent agent, CancellationToken cancellationToken)
    {
        return agent.WhileServingAsync(
            client: async () =>
                await new SshAgentKeyState().KeyStateAsync(socket: agent.Path, cancellationToken: cancellationToken),
            cancellationToken: cancellationToken
        );
    }

    private static byte[] Framed(byte[] reply)
    {
        return [.. SshWire.U32((uint)reply.Length), .. reply];
    }
}
