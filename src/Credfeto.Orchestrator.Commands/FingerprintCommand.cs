using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

[DebuggerDisplay(
    "Kind={Kind}, TrustedFile={TrustedFile}, ReviewCommentsFile={ReviewCommentsFile}, PlanApproved={PlanApproved}, SchemaVersion={SchemaVersion}"
)]
public sealed record FingerprintCommand(
    FingerprintKind Kind,
    string? TrustedFile,
    string? ReviewCommentsFile,
    string? PlanApproved,
    int SchemaVersion
);
