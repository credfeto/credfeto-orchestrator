using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.Jq;

// What jq reports as an error: the filter (and so the shell function running it) fails
[Description("jq failed")]
public sealed partial class JqException : Exception;
