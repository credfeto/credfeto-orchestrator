using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Predicates;

// The lib/github-status routing reads over a pull request: which phase a session on it starts from, whether its
// merge state lets it be called settled, and the board-move comment after a clean review. Each answers as its shell
// function does, using the same predicates (a predicate whose jq would fail answers false, as there)
public static class PullRequestRouting
{
    private const string HUMAN_REVIEW = "Human Review";

    private const string FINALIZE = "PHASE H (finalize)";

    private const string ARMED_BUT_STUCK =
        "PHASE C (auto-merge is armed but the PR cannot merge: find and fix what is stopping it)";

    private const string LINKED_ISSUE_WORK =
        "PHASE C (finish any outstanding linked-issue work), otherwise PHASE D (simplify)";

    // pr_next_phase_for_board_status's case over the board status, all but Human Review
    private static readonly IReadOnlyDictionary<string, string> PhaseByBoardStatus = new Dictionary<string, string>(
        StringComparer.Ordinal
    )
    {
        ["Not Started"] = LINKED_ISSUE_WORK,
        ["Planning"] = LINKED_ISSUE_WORK,
        ["Approved"] = LINKED_ISSUE_WORK,
        ["Development"] = LINKED_ISSUE_WORK,
        ["AI Simplify"] = "PHASE D (simplify)",
        ["AI Review"] = "PHASE E (code review)",
        ["AI Security Review"] = "PHASE F (security review)",
        ["AI Coverage"] = "PHASE G (coverage)",
    };

    // pr_clean_review_status_comment's case over the status the board moves to
    private static readonly IReadOnlyDictionary<string, string> CleanReviewComments = new Dictionary<string, string>(
        StringComparer.Ordinal
    )
    {
        ["AI Security Review"] =
            "Code review clean - advancing to security review (board moved by the orchestrator: the session "
            + "reported no findings but did not move it)",
        ["AI Coverage"] =
            "Security review clean, advancing to coverage check (board moved by the orchestrator: the session "
            + "reported no findings but did not move it)",
    };

    // pr_next_phase_for_board_status: a failed required check, a failed check whose required-ness could not be
    // looked up (when requiredChecksUnknown is "true") and requested changes come first, then the board status
    // names the phase. Holds false, printing nothing, where the function returns 2 (no phase)
    public static ChecksAnswer NextPhase(string boardStatus, string pullRequestJson, string requiredChecksUnknown)
    {
        if (PullRequestPredicates.HasFailedRequiredCheck(pullRequestJson).Holds)
        {
            return ChecksAnswer.Printing("PHASE C (fix the failed required check)");
        }

        if (
            StringComparer.Ordinal.Equals(x: requiredChecksUnknown, y: "true")
            && PullRequestPredicates.HasFailedCheckOfUnknownRequiredness(pullRequestJson).Holds
        )
        {
            return ChecksAnswer.Printing(
                "PHASE C (fix the failed check: whether it is required could not be looked up)"
            );
        }

        if (PullRequestPredicates.HasUnaddressedReviewRequest(pullRequestJson).Holds)
        {
            return ChecksAnswer.Printing("PHASE C (address the requested changes)");
        }

        if (StringComparer.Ordinal.Equals(x: boardStatus, y: HUMAN_REVIEW))
        {
            return ChecksAnswer.Printing(
                PullRequestPredicates.HasNoAutoMergeRequest(pullRequestJson).Holds ? FINALIZE : ARMED_BUT_STUCK
            );
        }

        return PhaseByBoardStatus.TryGetValue(key: boardStatus, value: out string? phase)
            ? ChecksAnswer.Printing(phase)
            : ChecksAnswer.Of(holds: false);
    }

    // pr_merge_state_allows_settled: never when DIRTY, when BEHIND only while a review is still required, and
    // otherwise always
    public static ChecksAnswer MergeStateAllowsSettled(string pullRequestJson, string mergeState)
    {
        if (StringComparer.Ordinal.Equals(x: mergeState, y: "DIRTY"))
        {
            return ChecksAnswer.Of(holds: false);
        }

        return StringComparer.Ordinal.Equals(x: mergeState, y: "BEHIND")
            ? ChecksAnswer.Of(PullRequestPredicates.NeedsReviewApproval(pullRequestJson).Holds)
            : ChecksAnswer.Of(holds: true);
    }

    // pr_clean_review_status_comment: the comment for the status a clean review moves the board to, or nothing
    public static ChecksAnswer CleanReviewStatusComment(string status)
    {
        return CleanReviewComments.TryGetValue(key: status, value: out string? comment)
            ? ChecksAnswer.Printing(comment)
            : ChecksAnswer.Of(holds: false);
    }
}
