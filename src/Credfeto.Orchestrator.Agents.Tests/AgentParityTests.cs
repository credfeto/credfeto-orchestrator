using System;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

// Every fixture case, put at a socket path as the bats file puts it: the tool must exit with the status the shell
// function returned (4 for its 2) and send only the identities request, or refuse the cases marked "refuses"
public sealed class AgentParityTests : TestBase
{
    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return AgentParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheQueryMatchesTheShellFunctionAsync(int index, string name)
    {
        Assert.NotEmpty(name);
        CancellationToken cancellationToken = this.CancellationToken();
        AgentParityCase parity = await AgentParityFixture.CaseAsync(index: index, cancellationToken: cancellationToken);
        using TestDirectory directory = new();
        string socket = Path.Combine(path1: directory.Path, path2: "agent.sock");
        using FakeSshAgent? agent = StartAgent(parity: parity, directory: directory.Path, socket: ref socket);
        await using StringWriter error = new();
        string[] args = ["agent", "ssh-key-state", "--socket", socket];

        int status = agent is null
            ? await RunAsync(args: args, error: error, cancellationToken: cancellationToken)
            : await agent.WhileServingAsync(
                client: () => RunAsync(args: args, error: error, cancellationToken: cancellationToken),
                cancellationToken: cancellationToken
            );

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
        {
            Assert.Equal(expected: AgentCommandRunner.Refused, actual: status);

            return;
        }

        Assert.Equal(expected: parity.Status == 2 ? AgentCommandRunner.Unreachable : parity.Status, actual: status);
        Assert.Equal(expected: string.Empty, actual: error.ToString());

        if (agent is not null)
        {
            Assert.Equal(expected: ["000000010b"], actual: agent.Requests.ToArray());
        }
    }

    private static async Task<int> RunAsync(string[] args, StringWriter error, CancellationToken cancellationToken)
    {
        return await AgentCommandRunner
            .CreateDefault()
            .RunAsync(args: args, error: error, cancellationToken: cancellationToken);
    }

    private static FakeSshAgent? StartAgent(AgentParityCase parity, string directory, ref string socket)
    {
        switch (parity.Agent)
        {
            case "reply":
                return FakeSshAgent.Start(directory: directory, reply: Convert.FromHexString(parity.Reply));
            case "file":
                File.WriteAllBytes(path: socket, bytes: []);

                return null;
            case "directory":
                Directory.CreateDirectory(socket);

                return null;
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

                return null;
            case "long-path":
                socket = Path.Combine(path1: directory, path2: new string(c: 'x', count: 120));

                return null;
            case "missing":
                return null;
            default:
                throw new InvalidOperationException("Unknown agent kind " + parity.Agent);
        }
    }
}
