using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class ProcProcessTableTests : TestBase
{
    [Fact]
    public async Task EachProcessIsReadAsProcpsReadsItAsync()
    {
        using TestDirectory directory = new();
        await this.WriteProcessAsync(
            root: directory.Path,
            pid: "10",
            uids: "1000\t1002",
            commandLine: "ssh-agent\0-a\0/s\0"
        );
        await this.WriteProcessAsync(root: directory.Path, pid: "11", uids: "1000\t1002", commandLine: string.Empty);
        await this.WriteProcessAsync(root: directory.Path, pid: "12", uids: "1\tbad", commandLine: "a\0");
        await this.WriteProcessAsync(root: directory.Path, pid: "self", uids: "1\t1", commandLine: "a\0");
        Directory.CreateDirectory(Path.Combine(path1: directory.Path, path2: "13"));

        IReadOnlyList<ProcessEntry> processes = await new ProcProcessTable(directory.Path).ProcessesAsync(
            this.CancellationToken()
        );

        Assert.Equal(
            expected: ["10 1002 ssh-agent -a /s", "11 1002 [comm-11]"],
            actual: processes.OrderBy(process => process.Pid).Select(Describe).ToArray()
        );
    }

    [Fact]
    public async Task TheRealProcessTableHoldsThisProcessAsync()
    {
        IReadOnlyList<ProcessEntry> processes = await new ProcProcessTable("/proc").ProcessesAsync(
            this.CancellationToken()
        );

        Assert.Contains(collection: processes, filter: process => process.Pid == Environment.ProcessId);
    }

    private static string Describe(ProcessEntry process)
    {
        return $"{process.Pid} {process.EffectiveUid} {Encoding.Latin1.GetString(process.Text.Span)}";
    }

    // A proc directory for one process: status with the real and effective uids given (then two more), the command
    // line as given, and comm "comm-<pid>" with its newline
    private async Task WriteProcessAsync(string root, string pid, string uids, string commandLine)
    {
        string directory = Path.Combine(path1: root, path2: pid);
        Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(
            path: Path.Combine(path1: directory, path2: "status"),
            contents: $"Name:\tx\nUid:\t{uids}\t1000\t1000\nGid:\t1\t1\t1\t1\n",
            cancellationToken: this.CancellationToken()
        );
        await File.WriteAllBytesAsync(
            path: Path.Combine(path1: directory, path2: "cmdline"),
            bytes: Encoding.Latin1.GetBytes(commandLine),
            cancellationToken: this.CancellationToken()
        );
        await File.WriteAllTextAsync(
            path: Path.Combine(path1: directory, path2: "comm"),
            contents: $"comm-{pid}\n",
            cancellationToken: this.CancellationToken()
        );
    }
}
