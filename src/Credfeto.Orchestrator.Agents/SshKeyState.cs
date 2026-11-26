namespace Credfeto.Orchestrator.Agents;

// What ssh-add -l would say of the agent: KEYS (exit 0) it lists at least one key, NO_KEYS (exit 1) the agent holds
// none or its reply is an error or one ssh-add rejects, UNREACHABLE (exit 2) nothing could be connected to
public enum SshKeyState
{
    KEYS,
    NO_KEYS,
    UNREACHABLE,
}
