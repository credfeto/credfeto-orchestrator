using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Credfeto.Orchestrator.State.Tests;

// What the fixtures need that .NET has no API for: the umask, hard links and FIFOs
[SupportedOSPlatform("linux")]
internal static partial class NativeMethods
{
    // Sets the process umask, returning the one it replaces
    public static int SetUmask(int mask)
    {
        return Umask(mask);
    }

    public static void HardLink(string existing, string path)
    {
        if (Link(existing: existing, path: path) != 0)
        {
            throw new IOException("link " + path + " failed: " + Errno());
        }
    }

    public static void Fifo(string path)
    {
        if (MakeFifo(path: path, mode: 0x1A4) != 0)
        {
            throw new IOException("mkfifo " + path + " failed: " + Errno());
        }
    }

    private static string Errno()
    {
        return Marshal.GetLastPInvokeError().ToString(CultureInfo.InvariantCulture);
    }

    [LibraryImport("libc", EntryPoint = "umask")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static partial int Umask(int mask);

    [LibraryImport("libc", EntryPoint = "link", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static partial int Link(string existing, string path);

    [LibraryImport("libc", EntryPoint = "mkfifo", StringMarshalling = StringMarshalling.Utf8, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static partial int MakeFifo(string path, int mode);
}
