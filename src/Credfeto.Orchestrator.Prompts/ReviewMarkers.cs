using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// ROUND_MARKER_* and REVIEW_RESULT_*_MARKER (lib/globals)
[DebuggerDisplay("Simplify={Simplify}, Clean={ReviewResultClean}")]
public sealed record ReviewMarkers(
    string Simplify,
    string CodeReview,
    string SecurityReview,
    string Coverage,
    string ReviewResultClean,
    string ReviewResultFindings
);
