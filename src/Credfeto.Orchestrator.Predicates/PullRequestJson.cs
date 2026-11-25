using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// The lib/github-status functions that read a value out of a pull request's JSON, or annotate it,
// each printing what the shell function prints
public static partial class PullRequestJson
{
    private const string ROLLUP = "statusCheckRollup";
    private const string IS_REQUIRED = "isRequired";
    private const string NOT_YET_REPORTED = "requiredChecksNotYetReported";

    private const int MATCH_TIMEOUT_MILLISECONDS = 1000;

    // annotate_pr_json_required_checks: pullRequestJson with each statusCheckRollup entry's
    // isRequired set from requiredNamesJson (fetch_pr_required_check_names), and
    // requiredChecksNotYetReported where a required check has not reported, judged by
    // baseRequiresChecks ("true", "false" or empty) when no name is required. Prints jq -c's output,
    // and the input unchanged where the shell skips jq or jq fails.
    public static string AnnotateRequiredChecks(
        string pullRequestJson,
        string requiredNamesJson,
        string baseRequiresChecks
    )
    {
        if (requiredNamesJson.Length == 0)
        {
            return pullRequestJson;
        }

        if (
            StringComparer.Ordinal.Equals(x: requiredNamesJson, y: "[]")
            && !StringComparer.Ordinal.Equals(x: baseRequiresChecks, y: "true")
            && !StringComparer.Ordinal.Equals(x: baseRequiresChecks, y: "false")
        )
        {
            return pullRequestJson;
        }

        JqValue? required = JqProgram.TryParse(json: requiredNamesJson, problem: out _);
        JqValue? baseRequires = JqProgram.TryParse(
            json: baseRequiresChecks.Length == 0 ? "false" : baseRequiresChecks,
            problem: out _
        );

        if (required is null || baseRequires is null)
        {
            return pullRequestJson;
        }

        JqRun run = JqProgram.Run(input: pullRequestJson, program: pullRequest =>
            Annotate(pullRequest: pullRequest, required: required, baseRequires: baseRequires)
        );

        StringBuilder printed = new();

        foreach (JqValue output in run.Outputs)
        {
            printed.Append(JqFormatter.ToJson(output)).Append('\n');
        }

        return run.Succeeded ? printed.ToString() : printed.Append(pullRequestJson).ToString();
    }

    // pr_json_env_block_image_sha: the image SHA in the last comment carrying the agent's
    // <!-- orchestrator:env-block image-sha=<sha> --> marker; fails when no comment does
    public static PredicateOutput EnvBlockImageSha(string pullRequestJson)
    {
        // The shell ignores jq's status here: what the texts jq could read printed is the answer
        JqRun run = JqProgram.Run(input: pullRequestJson, program: static pullRequest =>
            LastEnvBlockImageSha(pullRequest)
        );
        string sha = JqProgram.Substituted(run.Outputs);

        return new(Succeeded: sha.Length != 0, Printed: sha, Problem: sha.Length == 0 ? run.Problem : null);
    }

    // pr_json_lowest_closing_issue: the lowest number among the Issues in repository the pull request
    // closes; fails when it closes none, or the references are absent or malformed
    public static PredicateOutput LowestClosingIssue(string pullRequestJson, string repository)
    {
        JqValue repositoryName = JqBuiltins.AsciiDowncase(JqValue.FromString(repository));
        JqRun run = JqProgram.Run(input: pullRequestJson, program: pullRequest =>
            LowestClosingIssue(pullRequest: pullRequest, repository: repositoryName)
        );

        // jq -e: an error, no output or a false/null last output fails
        if (!run.Holds)
        {
            return new(Succeeded: false, Printed: string.Empty, Problem: run.Succeeded ? null : run.Problem);
        }

        string issue = JqProgram.Substituted(run.Outputs);

        return IssueNumber().IsMatch(issue)
            ? new(Succeeded: true, Printed: issue, Problem: null)
            : new(Succeeded: false, Printed: string.Empty, Problem: null);
    }

    private static JqValue Annotate(JqValue pullRequest, JqValue required, JqValue baseRequires)
    {
        JqValue rollup = JqOps.Field(value: pullRequest, name: ROLLUP);

        if (rollup.Kind != JqKind.ARRAY)
        {
            return pullRequest;
        }

        if (JqBuiltins.Compare(left: JqOps.Length(required), right: JqValue.FromInteger(0)) > 0)
        {
            return AnnotateRequired(pullRequest: pullRequest, rollup: rollup, required: required);
        }

        if (baseRequires.IsTruthy)
        {
            JqValue optional = WithRequired(pullRequest: pullRequest, rollup: rollup, isRequired: static _ =>
                JqValue.False
            );

            return JqBuiltins.SetField(value: optional, name: NOT_YET_REPORTED, field: JqValue.True);
        }

        return WithRequired(pullRequest: pullRequest, rollup: rollup, isRequired: static _ => JqValue.True);
    }

    // .statusCheckRollup |= map(. + {isRequired: ((.name // .context) as $n | $required | index($n) != null)})
    // | [.statusCheckRollup[] | (.name // .context)] as $present
    // | if any($required[]; . as $r | $present | index($r) == null) then .requiredChecksNotYetReported = true else . end
    private static JqValue AnnotateRequired(JqValue pullRequest, JqValue rollup, JqValue required)
    {
        JqValue annotated = WithRequired(pullRequest: pullRequest, rollup: rollup, isRequired: check =>
            JqValue.FromBoolean(JqBuiltins.HasIndex(value: required, item: NameOrContext(check)))
        );
        JqValue present = JqValue.FromArray([
            .. JqOps.Iterate(JqOps.Field(value: annotated, name: ROLLUP)).Select(NameOrContext),
        ]);

        return JqOps.Iterate(required).Any(name => !JqBuiltins.HasIndex(value: present, item: name))
            ? JqBuiltins.SetField(value: annotated, name: NOT_YET_REPORTED, field: JqValue.True)
            : annotated;
    }

    private static JqValue WithRequired(JqValue pullRequest, JqValue rollup, Func<JqValue, JqValue> isRequired)
    {
        JqValue checks = JqBuiltins.Map(value: rollup, selector: check =>
            JqBuiltins.Add(left: check, right: JqValue.FromObject([new(Name: IS_REQUIRED, Value: isRequired(check))]))
        );

        return JqBuiltins.SetField(value: pullRequest, name: ROLLUP, field: checks);
    }

    private static JqValue NameOrContext(JqValue check)
    {
        return JqProgram.Or(
            value: JqOps.Field(value: check, name: "name"),
            fallback: JqOps.Field(value: check, name: "context")
        );
    }

    // [.comments[]?.body // "" | capture(...).sha] | last // empty
    private static JqValue? LastEnvBlockImageSha(JqValue pullRequest)
    {
        IReadOnlyList<JqValue> bodies =
        [
            .. JqBuiltins
                .IterateOptional(JqOps.Field(value: pullRequest, name: "comments"))
                .Select(static comment => JqOps.Field(value: comment, name: "body")),
        ];
        IReadOnlyList<JqValue> truthy = [.. bodies.Where(static body => body.IsTruthy)];
        JqValue? last = null;

        foreach (JqValue body in truthy.Count == 0 ? [JqValue.FromString(string.Empty)] : truthy)
        {
            if (body.Kind != JqKind.TEXT)
            {
                throw new JqException($"{body.TypeName()} cannot be matched, as it is not a string");
            }

            Match match = StatusPatterns.EnvBlock().Match(body.Text);

            if (match.Success)
            {
                last = JqValue.FromString(match.Groups["sha"].Value);
            }
        }

        return last;
    }

    // [(.closingIssuesReferences // [])[] | select(in this repository) | .number]
    // | if length > 0 and all(type == "number") then min else empty end
    private static JqValue? LowestClosingIssue(JqValue pullRequest, JqValue repository)
    {
        IReadOnlyList<JqValue> references = JqOps.Iterate(
            JqProgram.Or(
                value: JqOps.Field(value: pullRequest, name: "closingIssuesReferences"),
                fallback: JqValue.EmptyArray
            )
        );
        JqValue numbers = JqValue.FromArray([
            .. references
                .Where(reference => IsInRepository(reference: reference, repository: repository))
                .Select(static reference => JqOps.Field(value: reference, name: "number")),
        ]);

        return numbers.Items.Count != 0 && numbers.Items.All(static number => number.Kind == JqKind.NUMBER)
            ? JqBuiltins.Min(numbers)
            : null;
    }

    // .repository == null or (((.repository.owner.login // "") + "/" + (.repository.name // "")) | ascii_downcase) == ($repo | ascii_downcase)
    private static bool IsInRepository(JqValue reference, JqValue repository)
    {
        JqValue named = JqOps.Field(value: reference, name: "repository");

        if (JqBuiltins.Equal(left: named, right: JqValue.Null))
        {
            return true;
        }

        JqValue owner = JqOps.Alternative(
            value: JqProgram.Path(value: named, first: "owner", second: "login"),
            fallback: string.Empty
        );
        JqValue name = JqOps.Alternative(value: JqOps.Field(value: named, name: "name"), fallback: string.Empty);
        JqValue full = JqBuiltins.Add(left: JqBuiltins.Add(left: owner, right: JqValue.FromString("/")), right: name);

        return JqBuiltins.Equal(left: JqBuiltins.AsciiDowncase(full), right: repository);
    }

    // The shell's [[ "${issue}" =~ ^[0-9]+$ ]]
    [GeneratedRegex(
        pattern: "^[0-9]+\\z",
        options: RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex IssueNumber();
}
