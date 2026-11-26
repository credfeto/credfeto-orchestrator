using System.Diagnostics;

namespace Credfeto.Orchestrator.Agents.Tests;

// One case of test/fixtures/agents-stop-parity.json: the socket SSH_AUTH_SOCK names and the stand-in's argv[0], as
// printf %b text with @ROOT@ for the test's directory, whether the tool answers or refuses it, and whether pkill killed
// the stand-in (null where that depends on the procps version or the locale)
[DebuggerDisplay("Socket={Socket}, Tool={Tool}, Killed={Killed}")]
public sealed record AgentStopParityCase(string Socket, string Argv0, string Tool, bool? Killed);
