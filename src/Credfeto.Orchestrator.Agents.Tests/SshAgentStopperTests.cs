using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class SshAgentStopperTests : TestBase
{
    private const int OWN_PID = 50;

    private const uint UID = 1000;

    [Fact]
    public async Task OnlyTheUsersMatchingProcessesAreSignalledAsync()
    {
        FakeProcessTable processes = new FakeProcessTable()
            .With(pid: 10, uid: UID, text: "ssh-agent -a /run/a.sock")
            .With(pid: 11, uid: 0, text: "ssh-agent -a /run/a.sock")
            .With(pid: 12, uid: UID, text: "ssh-agent -a /run/b.sock")
            .With(pid: 13, uid: UID, text: "bash -c ssh-agent -a /run/a.sock; sleep 1")
            .With(pid: OWN_PID, uid: UID, text: "ssh-agent -a /run/a.sock")
            .With(pid: 14, uid: 2000, text: "ssh-agent\n-a /run/a.sock");

        FakeSignalSender signals = await this.StopAsync(processes: processes, socket: "/run/a.sock", user: "me");

        Assert.Equal(expected: [10, 13], actual: signals.Terminated);
    }

    [Fact]
    public async Task NoMatchSignalsNothingAsync()
    {
        FakeProcessTable processes = new FakeProcessTable().With(pid: 10, uid: UID, text: "sleep 30");

        FakeSignalSender signals = await this.StopAsync(processes: processes, socket: "/run/a.sock", user: "me");

        Assert.Empty(signals.Terminated);
    }

    [Fact]
    public async Task AnUncertainProcessRefusesBeforeAnySignalAsync()
    {
        FakeProcessTable processes = new FakeProcessTable()
            .With(pid: 10, uid: UID, text: "ssh-agent -a /run/a.sock")
            .With(pid: 11, uid: UID, text: "ssh-agent\t-a /run/a.sock");
        FakeSignalSender signals = new();
        SshAgentStopper stopper = Create(processes: processes, signals: signals);

        await Assert.ThrowsAsync<AgentRefusedException>(() =>
            stopper.StopAsync(socket: "/run/a.sock", user: "me", this.CancellationToken()).AsTask()
        );

        Assert.Empty(signals.Terminated);
    }

    [Theory]
    [InlineData("someone-else", "/run/a.sock")]
    [InlineData("me", "/run/a+.sock")]
    public async Task AnUnknownUserOrASocketItCannotMatchIsRefusedAsync(string user, string socket)
    {
        FakeProcessTable processes = new FakeProcessTable().With(pid: 10, uid: UID, text: "ssh-agent -a " + socket);
        FakeSignalSender signals = new();
        SshAgentStopper stopper = Create(processes: processes, signals: signals);

        await Assert.ThrowsAsync<AgentRefusedException>(() =>
            stopper.StopAsync(socket: socket, user: user, this.CancellationToken()).AsTask()
        );

        Assert.Empty(signals.Terminated);
    }

    private async Task<FakeSignalSender> StopAsync(FakeProcessTable processes, string socket, string user)
    {
        FakeSignalSender signals = new();

        await Create(processes: processes, signals: signals)
            .StopAsync(socket: socket, user: user, cancellationToken: this.CancellationToken());

        return signals;
    }

    private static SshAgentStopper Create(FakeProcessTable processes, FakeSignalSender signals)
    {
        return new(
            processes: processes,
            users: new FakeUserDirectory(name: "me", uid: UID),
            signals: signals,
            ownPid: OWN_PID
        );
    }
}
