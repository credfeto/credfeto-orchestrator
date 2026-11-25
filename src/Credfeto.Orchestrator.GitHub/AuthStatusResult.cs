using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's auth_status result the read uses; every other property is ignored
[DebuggerDisplay("Login={Login}")]
internal sealed record AuthStatusResult(string? Login);
