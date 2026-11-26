namespace Credfeto.Orchestrator.Agents;

public interface ISignalSender
{
    // Sends SIGTERM to the process; one that has gone or that cannot be signalled is passed over, as pkill does
    void Terminate(int pid);
}
