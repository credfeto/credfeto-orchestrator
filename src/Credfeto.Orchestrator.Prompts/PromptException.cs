using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.Prompts;

// The prompt could not be built from these inputs, so lib/prompts builds it in bash instead
[Description("The prompt could not be built")]
public sealed partial class PromptException : Exception;
