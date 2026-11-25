using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// _build_review_convergence_block's arguments for one review phase
[DebuggerDisplay("Label={Label}, NextStatus={NextStatus}")]
internal sealed record ReviewPhase(
    string Label,
    string NextStatus,
    string MaxIterations,
    string FixStep,
    string DownstreamNote,
    string MinRounds
);
