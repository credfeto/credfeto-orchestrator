using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class AgentCommandRunnerTests : TestBase
{
    [Theory]
    [InlineData(SshKeyState.KEYS, 0)]
    [InlineData(SshKeyState.NO_KEYS, AgentCommandRunner.NoKeys)]
    [InlineData(SshKeyState.UNREACHABLE, AgentCommandRunner.Unreachable)]
    public async Task TheAnswerIsTheExitStatusAsync(SshKeyState state, int expected)
    {
        FakeSshAgentKeyState keys = new() { State = state };

        (int status, string error) = await this.RunAsync(keys: keys, args: "agent|ssh-key-state|--socket|/run/a.sock");

        Assert.Equal(expected: expected, actual: status);
        Assert.Equal(expected: string.Empty, actual: error);
        Assert.Equal(expected: ["/run/a.sock"], actual: keys.Asked);
    }

    [Fact]
    public async Task AUsageErrorPrintsTheUsageAsync()
    {
        FakeSshAgentKeyState keys = new();

        (int status, string error) = await this.RunAsync(keys: keys, args: "agent|ssh-key-state");

        Assert.Equal(expected: AgentCommandRunner.Usage, actual: status);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: agent ssh-key-state needs --socket <path>",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Contains(
            expectedSubstring: "Usage: credfeto-orchestrator agent ssh-key-state --socket <path>",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Empty(keys.Asked);
    }

    [Fact]
    public async Task ARefusedQueryExitsThreeAsync()
    {
        FakeSshAgentKeyState keys = new()
        {
            Failure = new AgentRefusedException("the agent holds a key of a type the tool does not judge"),
        };

        (int status, string error) = await this.RunAsync(keys: keys, args: "agent|ssh-key-state|--socket|s");

        Assert.Equal(expected: AgentCommandRunner.Refused, actual: status);
        Assert.Equal(
            expected: "credfeto-orchestrator: agent: the agent holds a key of a type the tool does not judge\n",
            actual: error
        );
    }

    [Fact]
    public async Task ACancelledQueryExits130Async()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();
        await using StringWriter error = new();

        int status = await new AgentCommandRunner(new FakeSshAgentKeyState()).RunAsync(
            args: ["agent", "ssh-key-state", "--socket", "s"],
            error: error,
            cancellationToken: cancelled.Token
        );

        Assert.Equal(expected: AgentCommandRunner.Cancelled, actual: status);
    }

    [Fact]
    public async Task TheDefaultRunnerAsksARealSocketAsync()
    {
        using TestDirectory directory = new();
        await using StringWriter error = new();

        int status = await AgentCommandRunner
            .CreateDefault()
            .RunAsync(
                args: ["agent", "ssh-key-state", "--socket", Path.Combine(path1: directory.Path, path2: "none.sock")],
                error: error,
                cancellationToken: this.CancellationToken()
            );

        Assert.Equal(expected: AgentCommandRunner.Unreachable, actual: status);
    }

    private async Task<(int Status, string Error)> RunAsync(FakeSshAgentKeyState keys, string args)
    {
        await using StringWriter error = new();

        int status = await new AgentCommandRunner(keys).RunAsync(
            args: args.Split('|'),
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (status, error.ToString());
    }
}
