using System.Runtime.InteropServices;

namespace Credfeto.Orchestrator.Agents;

// Sends SIGTERM with kill(2): .NET's Process.Kill sends SIGKILL, and an ssh-agent killed that way leaves its socket
// behind, which stops the next run's ssh-agent -a from binding there
public sealed partial class PosixSignalSender : ISignalSender
{
    private const int SIGTERM = 15;

    public void Terminate(int pid)
    {
        // ESRCH (gone) and EPERM (not ours) are passed over, as pkill || true does
        _ = Kill(pid: pid, signal: SIGTERM);
    }

    [LibraryImport("libc", EntryPoint = "kill", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static partial int Kill(int pid, int signal);
}
