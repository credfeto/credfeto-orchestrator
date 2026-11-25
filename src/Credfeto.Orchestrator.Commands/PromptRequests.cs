using System;
using Credfeto.Orchestrator.Prompts;

namespace Credfeto.Orchestrator.Commands;

// Turns the records into the builders' requests
internal static class PromptRequests
{
    public static IssueClaudeMdRequest Issue(PromptRecords records)
    {
        return new(
            Board: Board(records),
            ItemId: records["item"],
            AiInstructions: records["ai-instructions"],
            RepositoryPath: records["repo-path"],
            PlanApproved: records["plan-approved"],
            TrustedLogins: records["trusted-logins"],
            Tree: new(DirtyBranch: records["dirty-branch"], StaleBranch: records["stale-branch"]),
            BackgroundStall: records["background-stall"],
            PrecheckSection: records["precheck-section"]
        );
    }

    public static PullRequestClaudeMdRequest PullRequest(PromptRecords records)
    {
        return new(
            Board: Board(records),
            Review: Review(records),
            ItemId: records["item"],
            AiInstructions: records["ai-instructions"],
            MergeState: records["merge-state"],
            BranchName: records["branch"],
            RepositoryPath: records["repo-path"],
            DirtyBranch: records["dirty-branch"],
            Session: new(
                IsDependencyPullRequest: records["dependency-pr"],
                DependencyBranch: records["dependency-branch"],
                TrustedLogins: records["trusted-logins"],
                BackgroundStall: records["background-stall"],
                UnaddressedComments: records["unaddressed-comments"],
                NextPhase: records["next-phase"],
                PrecheckSection: records["precheck-section"]
            )
        );
    }

    public static LaunchPromptRequest Launch(PromptRecords records)
    {
        return new(Repository: records["repo-full"], ItemId: records["item"], RepositoryPath: records["repo-path"]);
    }

    public static PrecheckSectionRequest Precheck(PromptRecords records)
    {
        return new(
            SummaryLines: records["precheck-summary-lines"],
            TimeoutMinutes: records["precheck-timeout-minutes"],
            Kind: records["kind"],
            Sha: records["sha"],
            Status: records["status"],
            Summary: records["summary"],
            Error: records["error"],
            ContainerLog: records["container-log"]
        );
    }

    private static BoardSettings Board(PromptRecords records)
    {
        string board = records["board"];

        if (!StringComparer.Ordinal.Equals(x: board, y: "true") && !StringComparer.Ordinal.Equals(x: board, y: "false"))
        {
            throw new PromptException($"Record 'board' must be true or false, not '{board}'");
        }

        return new(
            Repository: records["repo-full"],
            HasBoard: StringComparer.Ordinal.Equals(x: board, y: "true"),
            Statuses: records.Statuses
        );
    }

    private static ReviewSettings Review(PromptRecords records)
    {
        return new(
            Markers: new(
                Simplify: records["round-marker-simplify"],
                CodeReview: records["round-marker-code-review"],
                SecurityReview: records["round-marker-security-review"],
                Coverage: records["round-marker-coverage"],
                ReviewResultClean: records["review-result-clean-marker"],
                ReviewResultFindings: records["review-result-findings-marker"]
            ),
            MaxSimplifyIterations: records["max-simplify-iterations"],
            SimplifyThrashLimit: records["simplify-thrash-limit"],
            MaxCodeReviewIterations: records["max-code-review-iterations"],
            MaxSecurityReviewIterations: records["max-security-review-iterations"],
            MaxCoverageIterations: records["max-coverage-iterations"],
            MinReviewConvergenceRounds: records["min-review-convergence-rounds"]
        );
    }
}
