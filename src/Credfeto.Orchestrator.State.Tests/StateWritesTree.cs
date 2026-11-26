using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.Versioning;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.State.Tests;

// The state directory of a test/fixtures/state-writes-parity.json case, built and listed as
// test/oneshot-state-writes-parity.bats builds and lists it
[SupportedOSPlatform("linux")]
internal static class StateWritesTree
{
    private const UnixFileMode OWNER_ALL = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;

    public static string Decoded(string text)
    {
        // An argument or name that is not UTF-8 reaches .NET with the bad bytes replaced, as on the command line
        return Encoding.UTF8.GetString(PrintfEscapes.Decode(text));
    }

    // The files, then their modes, last file first, so a directory's own mode comes after the files made in it
    public static async Task CreateAsync(
        string state,
        StateWritesParityCase parity,
        CancellationToken cancellationToken
    )
    {
        Directory.CreateDirectory(parity.SessionDirectory ? state + "/owner/repo" : state);
        List<(string Path, string Mode)> modes = [];

        foreach (StateWritesParityFile file in parity.Files)
        {
            string path = state + "/" + Decoded(file.Path);
            Directory.CreateDirectory(path[..path.AsSpan().LastIndexOf('/')]);
            await CreateAsync(state: state, path: path, file: file, cancellationToken: cancellationToken);
            modes.Insert(index: 0, item: (path, file.Mode));
        }

        foreach ((string path, string mode) in modes.Where(entry => entry.Mode.Length > 0))
        {
            File.SetUnixFileMode(path: path, mode: StateWritesParityFixture.ParseMode(mode));
        }
    }

    private static async Task CreateAsync(
        string state,
        string path,
        StateWritesParityFile file,
        CancellationToken cancellationToken
    )
    {
        if (file.Directory)
        {
            Directory.CreateDirectory(path);
        }
        else if (file.Link is not null)
        {
            File.CreateSymbolicLink(path: path, pathToTarget: Decoded(file.Link));
        }
        else if (file.HardLink is not null)
        {
            NativeMethods.HardLink(existing: state + "/" + Decoded(file.HardLink), path: path);
        }
        else
        {
            await File.WriteAllBytesAsync(
                path: path,
                bytes: PrintfEscapes.Decode(file.Content),
                cancellationToken: cancellationToken
            );
        }
    }

    // Every path under the state directory, links not followed, sorted bytewise: type, path, mode and the content or
    // link target, each as printf %b text
    public static async Task<IReadOnlyList<string>> ListAsync(string state, CancellationToken cancellationToken)
    {
        List<string> paths = [];
        AddEntries(directory: new(state), relative: ".", paths: paths);
        List<string> entries = [];

        foreach (byte[] path in paths.Select(Encoding.UTF8.GetBytes).Order(ByteOrder.Instance))
        {
            entries.Add(await EntryAsync(state: state, relative: path, cancellationToken: cancellationToken));
        }

        return entries;
    }

    private static async Task<string> EntryAsync(string state, byte[] relative, CancellationToken cancellationToken)
    {
        string path = state + "/" + Encoding.UTF8.GetString(relative)[2..];
        UnixFileStatus status = UnixFiles.Status(path)
            ?? throw new InvalidOperationException(path + " went away while listing");
        string name = PrintfEscapes.Encode(relative);
        string mode = StateWritesParityFixture.Mode(status.Permissions);

        if (status.IsSymbolicLink)
        {
            return $"l {name}  {PrintfEscapes.Encode(Encoding.UTF8.GetBytes(new FileInfo(path).LinkTarget ?? ""))}";
        }

        if (status.IsDirectory)
        {
            return $"d {name} {mode} ";
        }

        byte[] content = await File.ReadAllBytesAsync(path: path, cancellationToken: cancellationToken);

        return $"f {name} {mode} {PrintfEscapes.Encode(content)}";
    }

    private static void AddEntries(DirectoryInfo directory, string relative, List<string> paths)
    {
        foreach (FileSystemInfo entry in directory.EnumerateFileSystemInfos())
        {
            string path = relative + "/" + entry.Name;
            paths.Add(path);

            if (entry is DirectoryInfo subdirectory && entry.LinkTarget is null)
            {
                AddEntries(directory: subdirectory, relative: path, paths: paths);
            }
        }
    }

    // Read-only directories included
    public static void Remove(DirectoryInfo root)
    {
        foreach (
            DirectoryInfo directory in root.EnumerateDirectories(
                searchPattern: "*",
                new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }
            )
        )
        {
            directory.UnixFileMode |= OWNER_ALL;
        }

        root.Delete(recursive: true);
    }
}
