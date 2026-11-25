using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.Agents;

// The query cannot be answered exactly as the bash version would answer it, so bash must answer it
[Description("The agent query cannot be answered exactly as bash would")]
public sealed partial class AgentRefusedException : Exception;
