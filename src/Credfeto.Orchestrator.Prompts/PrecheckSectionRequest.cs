using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// build_precheck_section's arguments, with PRECHECK_SUMMARY_LINES and PRECHECK_TIMEOUT_MINUTES (lib/globals)
[DebuggerDisplay("Kind={Kind}, Sha={Sha}, Status={Status}")]
public sealed record PrecheckSectionRequest(
    string SummaryLines,
    string TimeoutMinutes,
    string Kind,
    string Sha,
    string Status,
    string Summary,
    string Error,
    string ContainerLog
);
