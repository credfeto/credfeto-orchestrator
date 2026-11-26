using System.Diagnostics;

namespace Credfeto.Orchestrator.Agents.Tests;

// One case of test/fixtures/agents-parity.json: what SSH_AUTH_SOCK names (Agent, with the Reply bytes a "reply"
// agent sends, as hex, length header included), whether the tool answers or refuses it, and the status
// ssh_agent_key_state returned in bash (ssh-add -l's)
[DebuggerDisplay("Agent={Agent}, Tool={Tool}, Status={Status}")]
public sealed record AgentParityCase(string Agent, string Reply, string Tool, int Status);
