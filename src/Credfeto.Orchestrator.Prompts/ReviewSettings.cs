using System.Diagnostics;

namespace Credfeto.Orchestrator.Prompts;

// The lib/globals round markers, review result markers and round budgets the pull request phases quote
[DebuggerDisplay("CodeReview={MaxCodeReviewIterations}, SecurityReview={MaxSecurityReviewIterations}")]
public sealed record ReviewSettings(
    ReviewMarkers Markers,
    string MaxSimplifyIterations,
    string SimplifyThrashLimit,
    string MaxCodeReviewIterations,
    string MaxSecurityReviewIterations,
    string MaxCoverageIterations,
    string MinReviewConvergenceRounds
);
