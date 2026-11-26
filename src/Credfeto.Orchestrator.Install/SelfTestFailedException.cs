using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.Install;

// A self-test check gave an answer other than the one built into it
[Description("A self-test check failed")]
public sealed partial class SelfTestFailedException : Exception;
