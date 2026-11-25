using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// The lib/github-status functions over a pull request's trusted comment activity: the pull request
// JSON (fetch_pr_json), the trusted logins (--argjson trusted, null trusting everyone), the REST
// inline review comments and issue comments (fetch_pr_review_comments / fetch_pr_issue_comments,
// as the text jq reads with --rawfile and fromjson) and the orchestrator's own login to leave out
public static class PullRequestComments
{
    private const string UPDATED_AT = "updated_at";

    // pr_json_latest_trusted_comment_timestamp: the newest trusted activity timestamp, or empty when
    // there is none; fails, printing nothing, where jq fails
    public static PredicateOutput LatestTrustedCommentTimestamp(
        string pullRequestJson,
        string trustedLoginsJson,
        string reviewCommentsJson,
        string issueCommentsJson,
        string excludeLogin
    )
    {
        JqValue? trusted = JqProgram.TryParse(json: trustedLoginsJson, problem: out string? problem);

        if (trusted is null)
        {
            return Failed(problem);
        }

        CountedLogins counted = new(trusted: trusted, me: excludeLogin);
        JqRun run = JqProgram.Run(input: pullRequestJson, program: pullRequest =>
            LatestTimestamp(
                pullRequest: pullRequest,
                counted: counted,
                reviewComments: JqParser.Parse(reviewCommentsJson),
                issueComments: JqParser.Parse(issueCommentsJson)
            )
        );

        return Printed(run);
    }

    // pr_json_has_unaddressed_trusted_comment: there is trusted activity, and it is newer than
    // lastSeenTimestamp (or nothing was seen yet). GitHub's timestamps are fixed-width ISO-8601 UTC,
    // so the shell's string comparison is an ordinal one.
    public static bool HasUnaddressedTrustedComment(
        string pullRequestJson,
        string trustedLoginsJson,
        string lastSeenTimestamp,
        string reviewCommentsJson,
        string issueCommentsJson,
        string excludeLogin
    )
    {
        string latest = LatestTrustedCommentTimestamp(
            pullRequestJson: pullRequestJson,
            trustedLoginsJson: trustedLoginsJson,
            reviewCommentsJson: reviewCommentsJson,
            issueCommentsJson: issueCommentsJson,
            excludeLogin: excludeLogin
        ).Printed;

        return latest.Length != 0
            && (lastSeenTimestamp.Length == 0 || string.CompareOrdinal(strA: latest, strB: lastSeenTimestamp) > 0);
    }

    // pr_json_unaddressed_trusted_comments_text, up to the shell's cap on the whole text: the trusted,
    // non-orchestrator activity newer than lastSeenTimestamp, oldest first, each body cut at
    // perCommentMaximum characters
    public static PredicateOutput UnaddressedTrustedCommentsText(
        string pullRequestJson,
        string trustedLoginsJson,
        string lastSeenTimestamp,
        string reviewCommentsJson,
        string issueCommentsJson,
        string excludeLogin,
        int perCommentMaximum
    )
    {
        JqValue? trusted = JqProgram.TryParse(json: trustedLoginsJson, problem: out string? problem);

        if (trusted is null)
        {
            return Failed(problem);
        }

        UnaddressedComments unaddressed = new(
            counted: new(trusted: trusted, me: excludeLogin),
            lastSeen: JqValue.FromString(lastSeenTimestamp),
            perCommentMaximum: perCommentMaximum
        );
        JqRun run = JqProgram.Run(input: pullRequestJson, program: pullRequest =>
            unaddressed.Text(
                pullRequest: pullRequest,
                reviewComments: JqParser.Parse(reviewCommentsJson),
                issueComments: JqParser.Parse(issueCommentsJson)
            )
        );

        return Printed(run);
    }

    private static JqValue LatestTimestamp(
        JqValue pullRequest,
        CountedLogins counted,
        JqValue reviewComments,
        JqValue issueComments
    )
    {
        List<JqValue> timestamps = [];

        // human(tc(.comments // []))[]? | (.updatedAt // .createdAt // "")
        timestamps.AddRange(
            Human(ByAuthor(comments: Comments(pullRequest: pullRequest, name: "comments"), counted: counted))
                .Select(static comment => FirstOf(comment: comment, first: "updatedAt", second: "createdAt"))
        );

        // tc(.reviews // [])[]? | (.submittedAt // .updatedAt // "")
        timestamps.AddRange(
            ByAuthor(comments: Comments(pullRequest: pullRequest, name: "reviews"), counted: counted)
                .Select(static review => FirstOf(comment: review, first: "submittedAt", second: "updatedAt"))
        );

        // trc($reviewComments)[]? | (.updated_at // "")
        timestamps.AddRange(
            ByUser(comments: reviewComments, counted: counted)
                .Select(static comment =>
                    JqOps.Alternative(value: JqOps.Field(value: comment, name: UPDATED_AT), fallback: string.Empty)
                )
        );

        // human(trc($issueComments))[]? | (.updated_at // .created_at // "")
        timestamps.AddRange(
            Human(ByUser(comments: issueComments, counted: counted))
                .Select(static comment => FirstOf(comment: comment, first: UPDATED_AT, second: "created_at"))
        );

        // map(select(. != "")) | sort | last // ""
        IReadOnlyList<JqValue> sorted = JqOps.Sort(
            timestamps.Where(static timestamp => !JqBuiltins.Equal(left: timestamp, right: string.Empty))
        );

        return sorted.Count == 0
            ? JqValue.FromString(string.Empty)
            : JqOps.Alternative(value: sorted[^1], fallback: string.Empty);
    }

    // (.<name> // [])
    internal static JqValue Comments(JqValue pullRequest, string name)
    {
        return JqProgram.Or(value: JqOps.Field(value: pullRequest, name: name), fallback: JqValue.EmptyArray);
    }

    // (.<first> // .<second> // "")
    internal static JqValue FirstOf(JqValue comment, string first, string second)
    {
        return JqOps.Alternative(
            value: JqProgram.Or(
                value: JqOps.Field(value: comment, name: first),
                fallback: JqOps.Field(value: comment, name: second)
            ),
            fallback: string.Empty
        );
    }

    // def tc(cs): cs | map(select(counted_login(.author.login)))
    private static IReadOnlyList<JqValue> ByAuthor(JqValue comments, CountedLogins counted)
    {
        return
        [
            .. JqOps
                .Iterate(comments)
                .Where(comment => counted.Counts(JqProgram.Path(value: comment, first: "author", second: "login"))),
        ];
    }

    // def trc(cs): cs | map(select(counted_login(.user.login)))
    private static IReadOnlyList<JqValue> ByUser(JqValue comments, CountedLogins counted)
    {
        return
        [
            .. JqOps
                .Iterate(comments)
                .Where(comment => counted.Counts(JqProgram.Path(value: comment, first: "user", second: "login"))),
        ];
    }

    // def human(cs): cs | map(select(automated_summary(.body) | not))
    private static IReadOnlyList<JqValue> Human(IReadOnlyList<JqValue> comments)
    {
        return
        [
            .. comments.Where(static comment =>
                !CountedLogins.IsAutomatedSummary(JqOps.Field(value: comment, name: "body"))
            ),
        ];
    }

    private static PredicateOutput Printed(JqRun run)
    {
        return run.Succeeded
            ? new(Succeeded: true, Printed: JqProgram.Substituted(run.Outputs), Problem: null)
            : Failed(run.Problem);
    }

    private static PredicateOutput Failed(string? problem)
    {
        return new(Succeeded: false, Printed: string.Empty, Problem: problem);
    }
}
