using System.Diagnostics;

namespace Credfeto.Orchestrator.Agents;

// Socket is the agent's socket path, as SSH_AUTH_SOCK names it; User is the user name stop-ssh-agent's processes
// belong to, as id -un prints it (empty for ssh-key-state)
[DebuggerDisplay("Query={Query}, Socket={Socket}, User={User}")]
public sealed record AgentCommand(AgentQuery Query, string Socket, string User = "");
