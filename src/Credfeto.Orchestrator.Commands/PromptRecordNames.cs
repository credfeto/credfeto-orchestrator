using System.Collections.Generic;

namespace Credfeto.Orchestrator.Commands;

// The records each prompt kind reads: build_*'s arguments after their defaults, then the lib/globals values it quotes
internal static class PromptRecordNames
{
    public static readonly IReadOnlyList<string> IssueClaudeMd =
    [
        "repo-full",
        "board",
        PromptRecords.Status,
        "item",
        "ai-instructions",
        "repo-path",
        "plan-approved",
        "trusted-logins",
        "dirty-branch",
        "stale-branch",
        "background-stall",
        "precheck-section",
    ];

    public static readonly IReadOnlyList<string> PullRequestClaudeMd =
    [
        "repo-full",
        "board",
        PromptRecords.Status,
        "round-marker-simplify",
        "round-marker-code-review",
        "round-marker-security-review",
        "round-marker-coverage",
        "review-result-clean-marker",
        "review-result-findings-marker",
        "max-simplify-iterations",
        "simplify-thrash-limit",
        "max-code-review-iterations",
        "max-security-review-iterations",
        "max-coverage-iterations",
        "min-review-convergence-rounds",
        "item",
        "ai-instructions",
        "merge-state",
        "branch",
        "repo-path",
        "dirty-branch",
        "dependency-pr",
        "trusted-logins",
        "background-stall",
        "unaddressed-comments",
        "next-phase",
        "precheck-section",
        "dependency-branch",
    ];

    public static readonly IReadOnlyList<string> Launch = ["repo-full", "item", "repo-path"];

    public static readonly IReadOnlyList<string> PrecheckSection =
    [
        "precheck-summary-lines",
        "precheck-timeout-minutes",
        "kind",
        "sha",
        "status",
        "summary",
        "error",
        "container-log",
    ];
}
