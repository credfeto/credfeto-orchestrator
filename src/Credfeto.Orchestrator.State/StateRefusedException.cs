using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.State;

// The query cannot be answered exactly as the bash version would answer it, so bash must answer it
[Description("The state query cannot be answered exactly as bash would")]
public sealed partial class StateRefusedException : Exception;
