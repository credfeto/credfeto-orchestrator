using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.GitHub;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Commands;

// Writes the JSON reads as jq -c prints the shell version's normalised gh output: compact, keys in the shell's order,
// and text escaped exactly as jq escapes it (control characters as \u00xx, everything else as itself), followed by a
// newline
public static class GitHubJsonOutput
{
    // [{"number":N,"author":{"login":L},"closingIssuesReferences":[{"number":M}],"headRefName":H}]
    public static string OpenPullRequests(IReadOnlyList<OpenPullRequestReferences> pullRequests)
    {
        return Text(JqValue.FromArray([.. pullRequests.Select(OpenPullRequest)]));
    }

    private static JqValue OpenPullRequest(OpenPullRequestReferences pullRequest)
    {
        return JqValue.FromObject([
            new(Name: "number", Value: JqValue.FromInteger(pullRequest.Number)),
            new(Name: "author", Value: Login(pullRequest.Author)),
            new(
                Name: "closingIssuesReferences",
                Value: JqValue.FromArray([.. pullRequest.ClosingIssues.Select(IssueNumber)])
            ),
            new(Name: "headRefName", Value: JqValue.FromString(pullRequest.Head)),
        ]);
    }

    private static JqValue IssueNumber(int issue)
    {
        return JqValue.FromObject([new(Name: "number", Value: JqValue.FromInteger(issue))]);
    }

    // {"commits":[{"authors":[{"login":L,"email":E}]}]}
    public static string Commits(IReadOnlyList<PullRequestCommit> commits)
    {
        return Text(JqValue.FromObject([new(Name: "commits", Value: JqValue.FromArray([.. commits.Select(Commit)]))]));
    }

    private static JqValue Commit(PullRequestCommit commit)
    {
        return JqValue.FromObject([new(Name: "authors", Value: JqValue.FromArray([.. commit.Authors.Select(Author)]))]);
    }

    private static JqValue Author(CommitAuthor author)
    {
        return JqValue.FromObject([
            new(Name: "login", Value: JqValue.FromString(author.Login)),
            new(Name: "email", Value: JqValue.FromString(author.Email)),
        ]);
    }

    // [{"user":{"login":L}|null,"path":P,"body":B,"updated_at":T}], the REST field names fetch_pr_review_comments'
    // callers read
    public static string ReviewComments(IReadOnlyList<PullRequestReviewComment> comments)
    {
        return Text(JqValue.FromArray([.. comments.Select(ReviewComment)]));
    }

    private static JqValue ReviewComment(PullRequestReviewComment comment)
    {
        return JqValue.FromObject([
            new(Name: "user", Value: User(comment.Login)),
            new(Name: "path", Value: JqValue.FromString(comment.Path)),
            new(Name: "body", Value: JqValue.FromString(comment.Body)),
            new(Name: "updated_at", Value: JqValue.FromString(comment.UpdatedAt)),
        ]);
    }

    // [{"user":{"login":L}|null,"body":B,"created_at":C,"updated_at":T}], the REST field names
    // fetch_pr_issue_comments' callers read
    public static string IssueComments(IReadOnlyList<PullRequestComment> comments)
    {
        return Text(JqValue.FromArray([.. comments.Select(IssueComment)]));
    }

    private static JqValue IssueComment(PullRequestComment comment)
    {
        return JqValue.FromObject([
            new(Name: "user", Value: User(comment.Login)),
            new(Name: "body", Value: JqValue.FromString(comment.Body)),
            new(Name: "created_at", Value: JqValue.FromString(comment.CreatedAt)),
            new(Name: "updated_at", Value: JqValue.FromString(comment.UpdatedAt)),
        ]);
    }

    private static JqValue User(string? login)
    {
        return login is null ? JqValue.Null : Login(login);
    }

    private static JqValue Login(string login)
    {
        return JqValue.FromObject([new(Name: "login", Value: JqValue.FromString(login))]);
    }

    private static string Text(JqValue value)
    {
        return JqFormatter.ToJson(value) + "\n";
    }
}
