using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Agents;

// Stops the run's ssh-agent as stop_ssh_agent's pkill -u <user> -f "ssh-agent -a <socket>" does: every process whose
// effective uid is the user's and whose command line the pattern matches (PkillPattern) gets SIGTERM, except this
// one, as pkill never signals itself. Every process is judged before any is signalled, so a refusal signals nothing.
public sealed class SshAgentStopper : ISshAgentStopper
{
    private readonly int _ownPid;
    private readonly IProcessTable _processes;
    private readonly ISignalSender _signals;
    private readonly IUserDirectory _users;

    public SshAgentStopper(IProcessTable processes, IUserDirectory users, ISignalSender signals, int ownPid)
    {
        this._processes = processes;
        this._users = users;
        this._signals = signals;
        this._ownPid = ownPid;
    }

    public static SshAgentStopper CreateDefault()
    {
        return new(
            processes: new ProcProcessTable("/proc"),
            users: new PasswdUserDirectory("/etc/passwd"),
            signals: new PosixSignalSender(),
            ownPid: Environment.ProcessId
        );
    }

    public async ValueTask StopAsync(string socket, string user, CancellationToken cancellationToken)
    {
        PkillPattern pattern = PkillPattern.ForSocket(socket);
        uint uid = await this._users.UidAsync(name: user, cancellationToken: cancellationToken)
            ?? throw new AgentRefusedException("the user name is not in the passwd file");
        IReadOnlyList<ProcessEntry> processes = await this._processes.ProcessesAsync(cancellationToken);
        List<int> matched = [];

        foreach (ProcessEntry process in processes)
        {
            if (process.EffectiveUid != uid || process.Pid == this._ownPid)
            {
                continue;
            }

            switch (pattern.Match(process.Text.Span))
            {
                case PkillMatch.MATCH:
                    matched.Add(process.Pid);

                    break;
                case PkillMatch.UNCERTAIN:
                    throw new AgentRefusedException(
                        "a process's command line holds bytes the tool does not match as procps would"
                    );
            }
        }

        cancellationToken.ThrowIfCancellationRequested();

        foreach (int pid in matched)
        {
            this._signals.Terminate(pid);
        }
    }
}
