using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman;

// What claude_result_indicates_clean_review passes: the two REVIEW_RESULT_*_MARKER lines and the joined
// CLEAN_REVIEW_PATTERNS, REVIEW_FINDINGS_PATTERNS and REVIEW_FINDINGS_NEGATED_PATTERNS (lib/globals)
[DebuggerDisplay("CleanMarker={CleanMarker}, FindingsMarker={FindingsMarker}")]
internal sealed record SessionTextPatterns(
    string CleanMarker,
    string FindingsMarker,
    string Clean,
    string Findings,
    string Negated
);
