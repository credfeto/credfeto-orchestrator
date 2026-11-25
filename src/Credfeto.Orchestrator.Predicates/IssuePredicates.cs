using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// The lib/github-status predicates over an Issue's JSON (fetch_issue_json's fields), each a port of
// its jq -e program. issue_json_has_human_plan_approval is the human gate on every implementation
// plan: it is ported exactly, and anything jq would fail on answers false (not approved).
public static class IssuePredicates
{
    private const string AUTHOR = "author";
    private const string LOGIN = "login";
    private const string BODY = "body";

    // issue_json_has_plan_comment: [.comments[]?.body // ""] | any(test("##\\s*Implementation Plan"; "i"))
    public static PredicateAnswer HasPlanComment(string issueJson)
    {
        return Evaluate(input: issueJson, predicate: static issue => HasPlanComment(issue));
    }

    // issue_json_has_human_plan_approval: a comment after the latest loose plan heading, with a line that
    // is not a quote and holds a sign-off keyword and no negation, by an approver association, from a
    // trusted login (trustedLoginsJson, --argjson, null trusting nobody) that is not a bot, not meLogin
    // and not the plan's own author
    public static PredicateAnswer HasHumanPlanApproval(string issueJson, string meLogin, string trustedLoginsJson)
    {
        JqValue? trusted = JqProgram.TryParse(json: trustedLoginsJson, problem: out string? problem);

        if (trusted is null)
        {
            return new(Holds: false, Problem: problem);
        }

        JqValue me = JqBuiltins.AsciiDowncase(JqValue.FromString(meLogin));

        return Evaluate(input: issueJson, predicate: issue =>
            HasHumanPlanApproval(issue: issue, me: me, trusted: trusted)
        );
    }

    private static bool HasPlanComment(JqValue issue)
    {
        // .comments[]?.body // "": every truthy body, or "" when there is none
        IReadOnlyList<JqValue> bodies =
        [
            .. JqBuiltins
                .IterateOptional(JqOps.Field(value: issue, name: "comments"))
                .Select(static comment => JqOps.Field(value: comment, name: BODY)),
        ];
        IReadOnlyList<JqValue> truthy = [.. bodies.Where(static body => body.IsTruthy)];

        return JqProgram.Any(
            items: truthy.Count == 0 ? [JqValue.FromString(string.Empty)] : truthy,
            condition: static body => JqProgram.Test(value: body, pattern: StatusPatterns.PlanComment())
        );
    }

    private static bool HasHumanPlanApproval(JqValue issue, JqValue me, JqValue trusted)
    {
        JqValue comments = JqProgram.Or(
            value: JqOps.Field(value: issue, name: "comments"),
            fallback: JqValue.EmptyArray
        );

        // [$c | to_entries[] | select(.value | loose_plan) | .key] | last
        int? plan = LatestPlan(comments);

        if (plan is null)
        {
            return false;
        }

        JqValue planBy = Login(comments.Items[plan.Value]);

        // ($trusted // []) | map(ascii_downcase)
        IReadOnlyList<JqValue> trustedLogins =
        [
            .. JqOps
                .Iterate(JqProgram.Or(value: trusted, fallback: JqValue.EmptyArray))
                .Select(JqBuiltins.AsciiDowncase),
        ];

        return JqProgram.Any(items: comments.Items.Skip(plan.Value + 1), condition: comment =>
            Approves(comment: comment, me: me, planBy: planBy, trustedLogins: trustedLogins)
        );
    }

    // The index of the last comment holding the loose plan heading. Every comment is looked at, as
    // to_entries does; on an object of comments the key found is a string, and $c[($i + 1):] then
    // fails in jq, so no object of comments is ever approved.
    private static int? LatestPlan(JqValue comments)
    {
        if (comments.Kind is not (JqKind.ARRAY or JqKind.DICTIONARY))
        {
            throw new JqException($"{comments.TypeName()} has no keys");
        }

        int? latest = null;
        IReadOnlyList<JqValue> values = JqOps.Iterate(comments);

        for (int index = 0; index < values.Count; index++)
        {
            if (IsLoosePlan(values[index]))
            {
                latest = index;
            }
        }

        if (latest is not null && comments.Kind == JqKind.DICTIONARY)
        {
            throw new JqException("string and number cannot be added");
        }

        return latest;
    }

    // def loose_plan: (.body // "") | test($loose; "i")
    private static bool IsLoosePlan(JqValue comment)
    {
        JqValue body = JqOps.Alternative(value: JqOps.Field(value: comment, name: BODY), fallback: string.Empty);

        if (body.Kind != JqKind.TEXT)
        {
            throw new JqException($"{body.TypeName()} cannot be matched, as it is not a string");
        }

        return PlanApprovalRule.IsLoosePlanHeading(body.Text);
    }

    private static bool Approves(JqValue comment, JqValue me, JqValue planBy, IReadOnlyList<JqValue> trustedLogins)
    {
        JqValue login = Login(comment);

        return !JqBuiltins.Equal(left: login, right: string.Empty)
            && !JqBuiltins.Equal(left: login, right: me)
            && !JqBuiltins.Equal(left: login, right: planBy)
            && trustedLogins.Any(trustedLogin => JqBuiltins.Equal(left: trustedLogin, right: login))
            && HasApprovalLine(comment)
            && IsApproverAssociation(comment)
            && !IsBotAuthor(comment);
    }

    // (.author.login // "" | ascii_downcase)
    private static JqValue Login(JqValue comment)
    {
        return JqBuiltins.AsciiDowncase(
            JqOps.Alternative(
                value: JqProgram.Path(value: comment, first: AUTHOR, second: LOGIN),
                fallback: string.Empty
            )
        );
    }

    // def approves: (.body // "") | split("\n") | any(.[]; rtrimstr("\r") | approval_line)
    private static bool HasApprovalLine(JqValue comment)
    {
        JqValue body = JqOps.Alternative(value: JqOps.Field(value: comment, name: BODY), fallback: string.Empty);

        return JqProgram.Any(items: JqBuiltins.Split(value: body, separator: "\n"), condition: static line =>
            PlanApprovalRule.IsApprovalLine(JqBuiltins.RTrimStr(value: line, suffix: "\r").Text)
        );
    }

    // def approver_association: (.authorAssociation // "") as $a | any($associations | split(" ")[]; . == $a)
    private static bool IsApproverAssociation(JqValue comment)
    {
        JqValue association = JqOps.Alternative(
            value: JqOps.Field(value: comment, name: "authorAssociation"),
            fallback: string.Empty
        );

        return PlanApprovalRule.ApproverAssociations.Any(approver =>
            JqBuiltins.Equal(left: association, right: approver)
        );
    }

    // def bot_author: (.author.login // "") | ascii_downcase | endswith("[bot]")
    private static bool IsBotAuthor(JqValue comment)
    {
        return JqBuiltins.EndsWith(value: Login(comment), suffix: "[bot]");
    }

    private static PredicateAnswer Evaluate(string input, System.Func<JqValue, bool> predicate)
    {
        return JqProgram.Holds(JqProgram.Run(input: input, program: issue => JqValue.FromBoolean(predicate(issue))));
    }
}
