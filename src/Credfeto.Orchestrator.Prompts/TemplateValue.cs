using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

[DebuggerDisplay("{Name}={Value}")]
internal readonly record struct TemplateValue(string Name, string Value);
