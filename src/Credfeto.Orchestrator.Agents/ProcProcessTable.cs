using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

// The processes under a proc file system, read as procps reads them: the effective uid from status's Uid line, the
// command line from cmdline, and the name from comm for a process whose command line is empty
public sealed class ProcProcessTable : IProcessTable
{
    private readonly string _root;

    public ProcProcessTable(string root)
    {
        this._root = root;
    }

    public async ValueTask<IReadOnlyList<ProcessEntry>> ProcessesAsync(CancellationToken cancellationToken)
    {
        List<ProcessEntry> processes = [];

        foreach (string directory in Directory.EnumerateDirectories(this._root))
        {
            if (
                !int.TryParse(
                    s: Path.GetFileName(directory),
                    style: NumberStyles.None,
                    provider: CultureInfo.InvariantCulture,
                    result: out int pid
                )
            )
            {
                continue;
            }

            ProcessEntry? process = await ReadAsync(
                directory: directory,
                pid: pid,
                cancellationToken: cancellationToken
            );

            if (process is not null)
            {
                processes.Add(process);
            }
        }

        return processes;
    }

    private static async ValueTask<ProcessEntry?> ReadAsync(
        string directory,
        int pid,
        CancellationToken cancellationToken
    )
    {
        try
        {
            uint? uid = EffectiveUid(
                await File.ReadAllLinesAsync(
                    path: Path.Combine(path1: directory, path2: "status"),
                    cancellationToken: cancellationToken
                )
            );

            if (uid is null)
            {
                return null;
            }

            byte[] commandLine = await File.ReadAllBytesAsync(
                path: Path.Combine(path1: directory, path2: "cmdline"),
                cancellationToken: cancellationToken
            );
            byte[] name =
                commandLine.Length == 0
                    ? await NameAsync(directory: directory, cancellationToken: cancellationToken)
                    : [];

            return new(
                Pid: pid,
                EffectiveUid: uid.Value,
                Text: PkillText.FromProcess(commandLine: commandLine, name: name)
            );
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // The process ended, or cannot be read: pkill passes it over too
            return null;
        }
    }

    private static async ValueTask<byte[]> NameAsync(string directory, CancellationToken cancellationToken)
    {
        byte[] name = await File.ReadAllBytesAsync(
            path: Path.Combine(path1: directory, path2: "comm"),
            cancellationToken: cancellationToken
        );

        return name.Length > 0 && name[^1] == (byte)'\n' ? name[..^1] : name;
    }

    // "Uid:" then the real, effective, saved and file-system uids, tab-separated
    private static uint? EffectiveUid(string[] status)
    {
        foreach (string line in status)
        {
            if (!line.StartsWith(value: "Uid:", comparisonType: StringComparison.Ordinal))
            {
                continue;
            }

            string[] fields = line.Split('\t', StringSplitOptions.RemoveEmptyEntries);

            return
                fields.Length > 2
                && uint.TryParse(fields[2], NumberStyles.None, CultureInfo.InvariantCulture, out uint uid)
                ? uid
                : null;
        }

        return null;
    }
}
