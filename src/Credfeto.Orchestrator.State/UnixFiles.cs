using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Credfeto.Orchestrator.State;

// lstat(2) through statx(2), whose buffer has the same layout on every architecture
[SupportedOSPlatform("linux")]
public static partial class UnixFiles
{
    private const int CURRENT_DIRECTORY = -100;
    private const int DO_NOT_FOLLOW_LINKS = 0x100;

    // STATX_TYPE, STATX_MODE, STATX_NLINK, STATX_UID and STATX_GID
    private const uint WANTED = 0x1F;

    private const int NOT_FOUND = 2;

    // struct statx: stx_nlink at 16, stx_uid at 20, stx_gid at 24 and stx_mode at 28, 256 bytes in all
    private const int BUFFER_SIZE = 256;
    private const int LINKS_OFFSET = 16;
    private const int OWNER_OFFSET = 20;
    private const int GROUP_OFFSET = 24;
    private const int MODE_OFFSET = 28;

    // null when nothing is at the path (a dangling link is something); refused when the path cannot be looked at (a
    // directory on the way that cannot be searched, or a part of it that is not a directory)
    public static UnixFileStatus? Status(string path)
    {
        Span<byte> buffer = stackalloc byte[BUFFER_SIZE];

        if (
            Statx(directory: CURRENT_DIRECTORY, path: path, flags: DO_NOT_FOLLOW_LINKS, mask: WANTED, buffer: buffer)
            == 0
        )
        {
            return new(
                Mode: MemoryMarshal.Read<ushort>(buffer[MODE_OFFSET..]),
                Links: MemoryMarshal.Read<uint>(buffer[LINKS_OFFSET..]),
                Owner: MemoryMarshal.Read<uint>(buffer[OWNER_OFFSET..]),
                Group: MemoryMarshal.Read<uint>(buffer[GROUP_OFFSET..])
            );
        }

        int error = Marshal.GetLastPInvokeError();

        return error == NOT_FOUND
            ? null
            : throw new StateRefusedException($"cannot look at {path}: {Marshal.GetPInvokeErrorMessage(error)}");
    }

    [LibraryImport("libc", EntryPoint = "statx", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static partial int Statx(int directory, string path, int flags, uint mask, Span<byte> buffer);
}
