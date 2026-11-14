using System.Diagnostics;

namespace Credfeto.Orchestrator.Fingerprints.Tests;

[DebuggerDisplay("Name={Name}, Expected={Expected}")]
public sealed record ParityCase(
    string Name,
    string Item,
    string? Trusted,
    string? ReviewComments,
    string? PlanApproved,
    string? Expected
);
