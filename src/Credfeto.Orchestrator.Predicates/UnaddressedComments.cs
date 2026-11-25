using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// pr_json_unaddressed_trusted_comments_text's jq program, with $trusted, $me, $last and $per bound
internal sealed class UnaddressedComments
{
    private const string BODY = "body";
    private const string COMMENT = "comment";
    private const string LOGIN = "login";

    private readonly CountedLogins _counted;
    private readonly JqValue _lastSeen;
    private readonly JqValue _perCommentMaximum;
    private readonly int _perCommentMaximumCount;

    public UnaddressedComments(CountedLogins counted, JqValue lastSeen, int perCommentMaximum)
    {
        this._counted = counted;
        this._lastSeen = lastSeen;
        this._perCommentMaximumCount = perCommentMaximum;
        this._perCommentMaximum = JqValue.FromInteger(perCommentMaximum);
    }

    public JqValue Text(JqValue pullRequest, JqValue reviewComments, JqValue issueComments)
    {
        List<UnaddressedComment> entries = [];
        entries.AddRange(JqBuiltins.IterateOptional(issueComments).Select(IssueComment));
        entries.AddRange(
            JqBuiltins
                .IterateOptional(PullRequestComments.Comments(pullRequest: pullRequest, name: "comments"))
                .Select(Comment)
        );
        entries.AddRange(
            JqBuiltins
                .IterateOptional(PullRequestComments.Comments(pullRequest: pullRequest, name: "reviews"))
                .Where(HasReviewText)
                .Select(Review)
        );
        entries.AddRange(JqBuiltins.IterateOptional(reviewComments).Select(InlineComment));

        // map(select(... counted_login ... newer than $last)) | map(select(not an automated summary))
        IReadOnlyList<UnaddressedComment> counted = [.. entries.Where(this.IsUnaddressed)];
        IReadOnlyList<UnaddressedComment> human = [.. counted.Where(static entry => !IsAutomated(entry))];

        // unique_by([.login, .kind, .body]) | sort_by(.ts)
        IReadOnlyList<UnaddressedComment> unique = UniqueByAuthorKindAndBody(human);
        IReadOnlyList<UnaddressedComment> oldestFirst =
        [
            .. unique.OrderBy(keySelector: static entry => entry.Timestamp, comparer: JqComparer.Instance),
        ];

        return JqValue.FromString(JqOps.Join(values: [.. oldestFirst.Select(this.Quoted)], separator: "\n"));
    }

    // {login: .user.login, ts: (.updated_at // .created_at // ""), kind: "comment", body: (.body // "")}
    private static UnaddressedComment IssueComment(JqValue comment)
    {
        return new(
            Login: JqProgram.Path(value: comment, first: "user", second: LOGIN),
            Timestamp: PullRequestComments.FirstOf(comment: comment, first: "updated_at", second: "created_at"),
            Kind: JqValue.FromString(COMMENT),
            Body: Body(comment)
        );
    }

    // {login: .author.login, ts: (.updatedAt // .createdAt // ""), kind: "comment", body: (.body // "")}
    private static UnaddressedComment Comment(JqValue comment)
    {
        return new(
            Login: JqProgram.Path(value: comment, first: "author", second: LOGIN),
            Timestamp: PullRequestComments.FirstOf(comment: comment, first: "updatedAt", second: "createdAt"),
            Kind: JqValue.FromString(COMMENT),
            Body: Body(comment)
        );
    }

    // select((.body // "") != "" or .state == "CHANGES_REQUESTED")
    private static bool HasReviewText(JqValue review)
    {
        return !JqBuiltins.Equal(left: Body(review), right: string.Empty)
            || JqBuiltins.Equal(left: JqOps.Field(value: review, name: "state"), right: "CHANGES_REQUESTED");
    }

    // {login: .author.login, ts: (.submittedAt // .updatedAt // ""), kind: ("review, " + (.state // "COMMENTED")), body}
    private static UnaddressedComment Review(JqValue review)
    {
        return new(
            Login: JqProgram.Path(value: review, first: "author", second: LOGIN),
            Timestamp: PullRequestComments.FirstOf(comment: review, first: "submittedAt", second: "updatedAt"),
            Kind: JqBuiltins.Add(
                left: "review, ",
                right: JqOps.Alternative(value: JqOps.Field(value: review, name: "state"), fallback: "COMMENTED")
            ),
            Body: Body(review)
        );
    }

    // {login: .user.login, ts: (.updated_at // ""), kind: ("inline review comment on " + (.path // "unknown file")), body}
    private static UnaddressedComment InlineComment(JqValue comment)
    {
        return new(
            Login: JqProgram.Path(value: comment, first: "user", second: LOGIN),
            Timestamp: JqOps.Alternative(
                value: JqOps.Field(value: comment, name: "updated_at"),
                fallback: string.Empty
            ),
            Kind: JqBuiltins.Add(
                left: "inline review comment on ",
                right: JqOps.Alternative(value: JqOps.Field(value: comment, name: "path"), fallback: "unknown file")
            ),
            Body: Body(comment)
        );
    }

    private static JqValue Body(JqValue comment)
    {
        return JqOps.Alternative(value: JqOps.Field(value: comment, name: BODY), fallback: string.Empty);
    }

    // .login != null and counted_login(.login) and .ts != "" and ($last == "" or .ts > $last)
    private bool IsUnaddressed(UnaddressedComment entry)
    {
        return !JqBuiltins.Equal(left: entry.Login, right: JqValue.Null)
            && this._counted.Counts(entry.Login)
            && !JqBuiltins.Equal(left: entry.Timestamp, right: string.Empty)
            && (
                this._lastSeen.Text.Length == 0 || JqBuiltins.Compare(left: entry.Timestamp, right: this._lastSeen) > 0
            );
    }

    // .kind != "comment" or (automated_summary(.body) | not), negated
    private static bool IsAutomated(UnaddressedComment entry)
    {
        return JqBuiltins.Equal(left: entry.Kind, right: COMMENT) && CountedLogins.IsAutomatedSummary(entry.Body);
    }

    private static IReadOnlyList<UnaddressedComment> UniqueByAuthorKindAndBody(
        IReadOnlyList<UnaddressedComment> entries
    )
    {
        // unique_by keys on the whole entry; the index keeps each key's first entry in the original order
        JqValue keyed = JqValue.FromArray([
            .. entries.Select(
                static (entry, index) =>
                    JqValue.FromArray([
                        JqValue.FromArray([entry.Login, entry.Kind, entry.Body]),
                        JqValue.FromInteger(index),
                    ])
            ),
        ]);

        return
        [
            .. JqBuiltins
                .UniqueBy(value: keyed, key: static pair => pair.Items[0])
                .Select(pair => entries[(int)pair.Items[1].Number]),
        ];
    }

    // "- \(.login) (\(.kind), \(.ts)):\n\(.body | clip)"
    private JqValue Quoted(UnaddressedComment entry)
    {
        return JqValue.FromString(
            "- "
                + JqOps.ToText(entry.Login)
                + " ("
                + JqOps.ToText(entry.Kind)
                + ", "
                + JqOps.ToText(entry.Timestamp)
                + "):\n"
                + JqOps.ToText(this.Clip(entry.Body))
        );
    }

    // clip: a body longer than $per is cut to its first $per characters (code points), marked as truncated
    private JqValue Clip(JqValue body)
    {
        if (JqBuiltins.Compare(left: JqOps.Length(body), right: this._perCommentMaximum) <= 0)
        {
            return body;
        }

        return JqBuiltins.Add(
            left: JqBuiltins.Take(value: body, count: this._perCommentMaximumCount),
            right: JqValue.FromString(" [truncated]")
        );
    }
}
