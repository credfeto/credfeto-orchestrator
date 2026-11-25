using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// lib/globals' _JQ_DEF_LATEST_CHECK_RUNS and _JQ_DEF_CHECK_FAILED
internal static class CheckRuns
{
    private static readonly IReadOnlyList<string> FailedConclusions =
    [
        "FAILURE",
        "CANCELLED",
        "TIMED_OUT",
        "ACTION_REQUIRED",
        "STALE",
        "STARTUP_FAILURE",
    ];

    // (.statusCheckRollup // [])
    public static JqValue Rollup(JqValue pullRequest)
    {
        return JqProgram.Or(
            value: JqOps.Field(value: pullRequest, name: "statusCheckRollup"),
            fallback: JqValue.EmptyArray
        );
    }

    // latest_check_runs: the checks grouped by name (or context) and workflow, in jq's order, and
    // the last run of each group by start (or completion) time
    public static IReadOnlyList<JqValue> Latest(JqValue checks)
    {
        return
        [
            .. JqBuiltins
                .GroupBy(value: checks, key: static check => JqValue.FromArray([NameOrContext(check), Workflow(check)]))
                .Select(static group =>
                    JqOps.Last(
                        JqOps.SortBy(value: JqValue.FromArray(group), key: static check => StartedOrCompleted(check))
                    )
                ),
        ];
    }

    // def check_failed: a CheckRun (it has .status) whose conclusion is unsuccessful, or a legacy
    // StatusContext whose state is FAILURE or ERROR
    public static bool Failed(JqValue check)
    {
        if (!JqBuiltins.Equal(left: JqOps.Field(value: check, name: "status"), right: JqValue.Null))
        {
            JqValue conclusion = JqOps.Alternative(value: JqOps.Field(value: check, name: "conclusion"), fallback: "");

            return FailedConclusions.Any(failed => JqBuiltins.Equal(left: conclusion, right: failed));
        }

        JqValue state = JqOps.Alternative(value: JqOps.Field(value: check, name: "state"), fallback: "");

        return JqBuiltins.Equal(left: state, right: "FAILURE") || JqBuiltins.Equal(left: state, right: "ERROR");
    }

    private static JqValue NameOrContext(JqValue check)
    {
        return JqOps.Alternative(
            value: JqProgram.Or(
                value: JqOps.Field(value: check, name: "name"),
                fallback: JqOps.Field(value: check, name: "context")
            ),
            fallback: ""
        );
    }

    private static JqValue Workflow(JqValue check)
    {
        return JqOps.Alternative(value: JqOps.Field(value: check, name: "workflowName"), fallback: "");
    }

    private static JqValue StartedOrCompleted(JqValue check)
    {
        return JqOps.Alternative(
            value: JqProgram.Or(
                value: JqOps.Field(value: check, name: "startedAt"),
                fallback: JqOps.Field(value: check, name: "completedAt")
            ),
            fallback: ""
        );
    }
}
