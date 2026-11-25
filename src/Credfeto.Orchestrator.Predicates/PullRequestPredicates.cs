using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// The lib/github-status predicates over a pull request's JSON (fetch_pr_json's fields), each a port
// of its jq -e program: input jq fails on, or that is not JSON, answers false with the problem, as
// the shell reads a jq failure
public static class PullRequestPredicates
{
    private const string PLACEHOLDER_FILE = ".deleteme.now";

    // pr_json_has_placeholder_file: (.files // []) | any(.[]; .path == ".deleteme.now")
    public static PredicateAnswer HasPlaceholderFile(string pullRequestJson)
    {
        return Evaluate(pullRequestJson: pullRequestJson, predicate: static pullRequest =>
            JqProgram.Any(items: JqOps.Iterate(Files(pullRequest)), condition: static file =>
                JqBuiltins.Equal(left: Path(file), right: PLACEHOLDER_FILE)
            )
        );
    }

    // pr_json_has_only_passed_checks: every entry a CheckRun that concluded SUCCESS, SKIPPED or NEUTRAL,
    // or a StatusContext in state SUCCESS
    public static PredicateAnswer HasOnlyPassedChecks(string pullRequestJson)
    {
        return Evaluate(pullRequestJson: pullRequestJson, predicate: static pullRequest =>
            JqProgram.All(items: JqOps.Iterate(CheckRuns.Rollup(pullRequest)), condition: static check => Passed(check))
        );
    }

    // pr_json_is_terminal: not a draft, no placeholder file, auto-merge armed (or the review pipeline
    // finished, reviewPipelineFinishedJson being its --argjson value), no CHANGES_REQUESTED, and no
    // latest check run that failed unless it is known not to be required
    public static PredicateAnswer IsTerminal(string pullRequestJson, string reviewPipelineFinishedJson)
    {
        JqValue? finished = JqProgram.TryParse(json: reviewPipelineFinishedJson, problem: out string? problem);

        if (finished is null)
        {
            return new(Holds: false, Problem: problem);
        }

        return Evaluate(pullRequestJson: pullRequestJson, predicate: pullRequest =>
            IsTerminal(pullRequest: pullRequest, finished: finished)
        );
    }

    // pr_json_has_failed_required_check: a latest check run known to be required has failed
    public static PredicateAnswer HasFailedRequiredCheck(string pullRequestJson)
    {
        return HasFailedLatestCheck(pullRequestJson: pullRequestJson, isRequired: JqValue.True);
    }

    // pr_json_has_failed_check_of_unknown_requiredness: a latest check run with no isRequired has failed
    public static PredicateAnswer HasFailedCheckOfUnknownRequiredness(string pullRequestJson)
    {
        return HasFailedLatestCheck(pullRequestJson: pullRequestJson, isRequired: JqValue.Null);
    }

    // pr_json_has_pending_ci_checks: required checks not yet reported, a head check run still running, or
    // a rollup entry not known to be optional that has not finished
    public static PredicateAnswer HasPendingCiChecks(string pullRequestJson)
    {
        return Evaluate(pullRequestJson: pullRequestJson, predicate: static pullRequest =>
            HasPendingCiChecks(pullRequest)
        );
    }

    // pr_json_has_unaddressed_review_request: .reviewDecision == "CHANGES_REQUESTED"
    public static PredicateAnswer HasUnaddressedReviewRequest(string pullRequestJson)
    {
        return HasReviewDecision(pullRequestJson: pullRequestJson, decision: "CHANGES_REQUESTED");
    }

    // pr_json_needs_review_approval: .reviewDecision == "REVIEW_REQUIRED"
    public static PredicateAnswer NeedsReviewApproval(string pullRequestJson)
    {
        return HasReviewDecision(pullRequestJson: pullRequestJson, decision: "REVIEW_REQUIRED");
    }

    private static PredicateAnswer HasReviewDecision(string pullRequestJson, string decision)
    {
        return Evaluate(pullRequestJson: pullRequestJson, predicate: pullRequest =>
            JqBuiltins.Equal(left: JqOps.Field(value: pullRequest, name: "reviewDecision"), right: decision)
        );
    }

    private static PredicateAnswer HasFailedLatestCheck(string pullRequestJson, JqValue isRequired)
    {
        return Evaluate(pullRequestJson: pullRequestJson, predicate: pullRequest =>
            JqProgram.Any(items: CheckRuns.Latest(CheckRuns.Rollup(pullRequest)), condition: check =>
                JqBuiltins.Equal(left: JqOps.Field(value: check, name: "isRequired"), right: isRequired)
                && CheckRuns.Failed(check)
            )
        );
    }

    private static bool IsTerminal(JqValue pullRequest, JqValue finished)
    {
        return !JqBuiltins.Equal(left: JqOps.Field(value: pullRequest, name: "isDraft"), right: JqValue.True)
            && JqProgram.All(items: JqOps.Iterate(Files(pullRequest)), condition: static file =>
                !JqBuiltins.Equal(left: Path(file), right: PLACEHOLDER_FILE)
            )
            && (
                !JqBuiltins.Equal(left: JqOps.Field(value: pullRequest, name: "autoMergeRequest"), right: JqValue.Null)
                || finished.IsTruthy
            )
            && !JqBuiltins.Equal(
                left: JqOps.Field(value: pullRequest, name: "reviewDecision"),
                right: "CHANGES_REQUESTED"
            )
            && JqProgram.All(items: CheckRuns.Latest(CheckRuns.Rollup(pullRequest)), condition: static check =>
                JqBuiltins.Equal(left: JqOps.Field(value: check, name: "isRequired"), right: JqValue.False)
                || !CheckRuns.Failed(check)
            );
    }

    private static bool HasPendingCiChecks(JqValue pullRequest)
    {
        if (
            JqBuiltins.Equal(
                left: JqOps.Field(value: pullRequest, name: "requiredChecksNotYetReported"),
                right: JqValue.True
            )
        )
        {
            return true;
        }

        if (JqBuiltins.Equal(left: JqOps.Field(value: pullRequest, name: "headCheckRunsRunning"), right: JqValue.True))
        {
            return true;
        }

        JqValue rollup = CheckRuns.Rollup(pullRequest);

        return JqBuiltins.Compare(left: JqOps.Length(rollup), right: JqValue.FromInteger(0)) > 0
            && JqProgram.Any(items: JqOps.Iterate(rollup), condition: static check =>
                !JqBuiltins.Equal(left: JqOps.Field(value: check, name: "isRequired"), right: JqValue.False)
                && Pending(check)
            );
    }

    // A CheckRun is pending while neither its status nor its conclusion says it is done
    private static bool Pending(JqValue check)
    {
        JqValue status = JqOps.Field(value: check, name: "status");

        if (!JqBuiltins.Equal(left: status, right: JqValue.Null))
        {
            return !JqBuiltins.Equal(left: status, right: "COMPLETED")
                && JqBuiltins.Equal(
                    left: JqOps.Alternative(value: JqOps.Field(value: check, name: "conclusion"), fallback: ""),
                    right: ""
                );
        }

        JqValue state = JqOps.Alternative(value: JqOps.Field(value: check, name: "state"), fallback: "");

        return JqBuiltins.Equal(left: state, right: "PENDING") || JqBuiltins.Equal(left: state, right: "EXPECTED");
    }

    private static bool Passed(JqValue check)
    {
        if (!JqBuiltins.Equal(left: JqOps.Field(value: check, name: "status"), right: JqValue.Null))
        {
            JqValue conclusion = JqOps.Alternative(value: JqOps.Field(value: check, name: "conclusion"), fallback: "");

            return JqBuiltins.Equal(left: conclusion, right: "SUCCESS")
                || JqBuiltins.Equal(left: conclusion, right: "SKIPPED")
                || JqBuiltins.Equal(left: conclusion, right: "NEUTRAL");
        }

        return JqBuiltins.Equal(
            left: JqOps.Alternative(value: JqOps.Field(value: check, name: "state"), fallback: ""),
            right: "SUCCESS"
        );
    }

    private static JqValue Files(JqValue pullRequest)
    {
        return JqProgram.Or(value: JqOps.Field(value: pullRequest, name: "files"), fallback: JqValue.EmptyArray);
    }

    private static JqValue Path(JqValue file)
    {
        return JqOps.Field(value: file, name: "path");
    }

    private static PredicateAnswer Evaluate(string pullRequestJson, System.Func<JqValue, bool> predicate)
    {
        return JqProgram.Holds(
            JqProgram.Run(input: pullRequestJson, program: pullRequest => JqValue.FromBoolean(predicate(pullRequest)))
        );
    }
}
