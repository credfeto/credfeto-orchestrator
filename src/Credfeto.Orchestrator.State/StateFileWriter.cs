using System;
using System.IO;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Credfeto.Orchestrator.State;

// Writes a state file as a complete temporary copy beside it, flushed to disk and then renamed over it, so a reader or
// a crash never sees half a file, while leaving the file looking as the shell function would have left it: the same
// bytes, and the mode, owner and group its replacement gives (StateReplacement). Anything a rename would leave
// differently is refused before anything is written, and a failure part-way removes the temporary copy, so in both
// cases the file is as it was and bash can write it instead.
[SupportedOSPlatform("linux")]
public static class StateFileWriter
{
    // save_precheck_result's own temporary file
    private const string BASH_TEMPORARY_SUFFIX = ".tmp";

    private const int RANDOM_CHARACTERS = 16;

    public static async ValueTask ReplaceAsync(
        string path,
        ReadOnlyMemory<byte> content,
        StateReplacement replacement,
        CancellationToken cancellationToken
    )
    {
        UnixFileStatus? existing = CheckTarget(path: path, replacement: replacement);
        string temporary = path + "." + RandomNumberGenerator.GetHexString(RANDOM_CHARACTERS, lowercase: true) + ".tmp";
        bool renamed = false;

        try
        {
            await WriteNewFileAsync(path: temporary, content: content, cancellationToken: cancellationToken);

            if (replacement == StateReplacement.IN_PLACE && existing is { } file)
            {
                KeepAttributes(temporary: temporary, existing: file, path: path);
            }

            File.Move(sourceFileName: temporary, destFileName: path, overwrite: true);
            renamed = true;
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new IOException(message: $"cannot write {path}: {exception.Message}", innerException: exception);
        }
        finally
        {
            if (!renamed)
            {
                RemoveTemporary(temporary);
            }
        }
    }

    // What a rename would leave as bash's write leaves it, or refused
    private static UnixFileStatus? CheckTarget(string path, StateReplacement replacement)
    {
        string directory = path[..(path.AsSpan().LastIndexOf('/') + 1)];

        if (!Directory.Exists(directory))
        {
            throw new StateRefusedException($"no directory {directory} yet: bash makes it");
        }

        UnixFileStatus? existing = UnixFiles.Status(path);

        if (existing is not { } file)
        {
            return replacement == StateReplacement.MOVED ? CheckNoBashTemporary(path) : null;
        }

        if (file.IsSymbolicLink || file.IsDirectory)
        {
            throw new StateRefusedException($"{path} is a link or a directory, which bash writes through or into");
        }

        return replacement == StateReplacement.MOVED ? CheckNoBashTemporary(path) : CheckWritableInPlace(path, file);
    }

    // printf > file writes into the one file, through every hard link to it, and fails on one it cannot write
    private static UnixFileStatus CheckWritableInPlace(string path, in UnixFileStatus file)
    {
        if (!file.IsRegularFile || file.Links != 1)
        {
            throw new StateRefusedException($"{path} is not a regular file with a single link, which bash writes into");
        }

        try
        {
            using SafeFileHandle handle = File.OpenHandle(
                path: path,
                mode: FileMode.Open,
                access: FileAccess.Write,
                share: FileShare.ReadWrite | FileShare.Delete
            );
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new StateRefusedException(
                message: $"cannot write {path}, so neither can bash: {exception.Message}",
                innerException: exception
            );
        }

        return file;
    }

    // save_precheck_result writes into a file.tmp it finds, whatever it is, before moving it
    private static UnixFileStatus? CheckNoBashTemporary(string path)
    {
        return UnixFiles.Status(path + BASH_TEMPORARY_SUFFIX) is null
            ? null
            : throw new StateRefusedException(
                $"{path}{BASH_TEMPORARY_SUFFIX} is already there, which bash writes into"
            );
    }

    private static async ValueTask WriteNewFileAsync(
        string path,
        ReadOnlyMemory<byte> content,
        CancellationToken cancellationToken
    )
    {
        // No mode given, so the umask decides it, as for the file printf > creates
        using SafeFileHandle handle = File.OpenHandle(
            path: path,
            mode: FileMode.CreateNew,
            access: FileAccess.Write,
            share: FileShare.None
        );
        await RandomAccess.WriteAsync(
            handle: handle,
            buffer: content,
            fileOffset: 0,
            cancellationToken: cancellationToken
        );
        RandomAccess.FlushToDisk(handle);
    }

    // The file printf > writes into keeps its mode, owner and group; a new file can only take the mode
    private static void KeepAttributes(string temporary, in UnixFileStatus existing, string path)
    {
        UnixFileStatus made = UnixFiles.Status(temporary)
            ?? throw new IOException($"{temporary} went away before it was renamed");

        if (made.Owner != existing.Owner || made.Group != existing.Group)
        {
            throw new StateRefusedException($"{path} has an owner or group a new file would not get");
        }

        File.SetUnixFileMode(path: temporary, mode: (UnixFileMode)existing.Permissions);
    }

    private static void RemoveTemporary(string temporary)
    {
        try
        {
            File.Delete(temporary);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Nothing more can be done: the file it was meant to replace is as it was
        }
    }
}
