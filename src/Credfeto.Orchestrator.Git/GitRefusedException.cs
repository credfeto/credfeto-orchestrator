using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.Git;

// The query cannot be answered exactly as the bash version would answer it, so bash must answer it
[Description("The git query cannot be answered exactly as bash would")]
public sealed partial class GitRefusedException : Exception;
