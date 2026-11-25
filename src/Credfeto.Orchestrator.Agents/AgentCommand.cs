using System.Diagnostics;

namespace Credfeto.Orchestrator.Agents;

// Socket is the agent's socket path, as SSH_AUTH_SOCK names it
[DebuggerDisplay("Query={Query}, Socket={Socket}")]
public sealed record AgentCommand(AgentQuery Query, string Socket);
