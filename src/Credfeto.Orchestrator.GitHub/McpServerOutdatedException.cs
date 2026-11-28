using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.GitHub;

// The cfwf MCP server answered, but it is older than the read needs, so the read is left to the shell version
[Description("The cfwf MCP server is older than the read needs")]
public sealed partial class McpServerOutdatedException : Exception;
