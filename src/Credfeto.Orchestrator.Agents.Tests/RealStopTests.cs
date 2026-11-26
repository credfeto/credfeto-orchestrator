using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

// The default runner against real processes: stand-ins started as exec -a "<argv0>" sleep 30, one matching the
// socket's pattern and one bound to another socket; only the first gets SIGTERM
[SupportedOSPlatform("linux")]
public sealed class RealStopTests : TestBase
{
    private const int SIGTERM_EXIT = 128 + 15;

    [Fact]
    public async Task OnlyTheMatchingStandInIsTerminatedAsync()
    {
        CancellationToken cancellationToken = this.CancellationToken();
        using TestDirectory directory = new();
        string socket = Path.Combine(path1: directory.Path, path2: "agent.sock");
        using Process agent = await StartStandInAsync(
            argv0: "ssh-agent -a " + socket,
            cancellationToken: cancellationToken
        );
        using Process decoy = await StartStandInAsync(
            argv0: "ssh-agent -a " + Path.Combine(path1: directory.Path, path2: "other.sock"),
            cancellationToken: cancellationToken
        );
        await using StringWriter error = new();

        try
        {
            int status = await AgentCommandRunner
                .CreateDefault()
                .RunAsync(
                    args: ["agent", "stop-ssh-agent", "--socket", socket, "--user", Environment.UserName],
                    error: error,
                    cancellationToken: cancellationToken
                );

            Assert.Equal(expected: 0, actual: status);
            Assert.Equal(expected: string.Empty, actual: error.ToString());
            await agent.WaitForExitAsync(cancellationToken);
            Assert.Equal(expected: SIGTERM_EXIT, actual: agent.ExitCode);
            Assert.False(condition: decoy.HasExited, userMessage: "The decoy on another socket was stopped too");
        }
        finally
        {
            Stop(agent);
            Stop(decoy);
        }
    }

    // Starts bash, which execs sleep with argv[0] set, and waits until the exec has happened, so the stand-in's
    // command line is "<argv0> 30" and no longer bash's own
    private static async Task<Process> StartStandInAsync(string argv0, CancellationToken cancellationToken)
    {
        ProcessStartInfo start = new("bash") { UseShellExecute = false };
        start.ArgumentList.Add("-c");
        start.ArgumentList.Add("exec -a \"$0\" sleep 30");
        start.ArgumentList.Add(argv0);
        Process process = Process.Start(start) ?? throw new InvalidOperationException("bash did not start");
        string commandLine = Path.Combine(
            path1: "/proc",
            path2: process.Id.ToString(CultureInfo.InvariantCulture),
            path3: "cmdline"
        );
        byte[] expected = Encoding.ASCII.GetBytes(argv0 + "\0");

        for (int attempt = 0; attempt < 500; attempt++)
        {
            byte[] text = await File.ReadAllBytesAsync(path: commandLine, cancellationToken: cancellationToken);

            if (text.AsSpan().StartsWith(expected))
            {
                return process;
            }

            await Task.Delay(millisecondsDelay: 10, cancellationToken: cancellationToken);
        }

        Stop(process);

        throw new InvalidOperationException("The stand-in never exec'd sleep");
    }

    private static void Stop(Process process)
    {
        if (!process.HasExited)
        {
            process.Kill();
        }
    }
}
