using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Fingerprints;

// A line-for-line port of fingerprint_pr_json / fingerprint_issue_json (lib/fingerprints). Each
// value below is one output of the jq filter: jq -r prints each on its own line, the shell's
// command substitution drops NUL bytes and trailing newlines, and the result is hashed with
// SHA-256 behind the schema version. Any jq error fails the whole fingerprint.
public sealed class FingerprintCalculator : IFingerprintCalculator
{
    private const string AUTHOR = "author";
    private const string USER = "user";
    private const string NONE = "none";
    private const string UNKNOWN = "UNKNOWN";

    public string PullRequest(
        string pullRequestJson,
        string? trustedLoginsJson,
        string? reviewCommentsJson,
        int schemaVersion
    )
    {
        try
        {
            return PullRequestFingerprint(
                pullRequestJson: pullRequestJson,
                trustedLoginsJson: trustedLoginsJson,
                reviewCommentsJson: reviewCommentsJson,
                schemaVersion: schemaVersion
            );
        }
        catch (JqException exception)
        {
            throw new FingerprintException(message: exception.Message, innerException: exception);
        }
    }

    public string Issue(string issueJson, string? trustedLoginsJson, string? planApproved, int schemaVersion)
    {
        try
        {
            return IssueFingerprint(
                issueJson: issueJson,
                trustedLoginsJson: trustedLoginsJson,
                planApproved: planApproved,
                schemaVersion: schemaVersion
            );
        }
        catch (JqException exception)
        {
            throw new FingerprintException(message: exception.Message, innerException: exception);
        }
    }

    private static string PullRequestFingerprint(
        string pullRequestJson,
        string? trustedLoginsJson,
        string? reviewCommentsJson,
        int schemaVersion
    )
    {
        JqValue trusted = ParseOptional(json: trustedLoginsJson, fallback: "null");
        JqValue reviewComments = ParseOptional(json: reviewCommentsJson, fallback: "[]");
        JqValue pullRequest = JqParser.Parse(pullRequestJson);

        List<string> lines = [];
        AddPullRequestHeader(lines: lines, pullRequest: pullRequest, trusted: trusted);
        AddPullRequestReviews(lines: lines, pullRequest: pullRequest, trusted: trusted);
        AddPullRequestPeople(lines: lines, pullRequest: pullRequest);
        AddPullRequestReviewComments(lines: lines, reviewComments: reviewComments, trusted: trusted);
        AddPullRequestChecks(lines: lines, pullRequest: pullRequest);

        return Finalise(lines: lines, schemaVersion: schemaVersion);
    }

    private static string IssueFingerprint(
        string issueJson,
        string? trustedLoginsJson,
        string? planApproved,
        int schemaVersion
    )
    {
        JqValue trusted = ParseOptional(json: trustedLoginsJson, fallback: "null");
        JqValue issue = JqParser.Parse(issueJson);

        List<string> lines =
        [
            JqFormatter.Raw(JqOps.Field(value: issue, name: "title")),
            JqFormatter.Raw(JqOps.Alternative(value: JqOps.Field(value: issue, name: "body"), fallback: string.Empty)),
            JqFormatter.Raw(JqOps.Field(value: issue, name: "state")),
        ];

        AddLabels(lines: lines, item: issue);

        JqValue comments = TrustedOnly(
            items: JqOps.Alternative(value: JqOps.Field(value: issue, name: "comments"), fallback: JqValue.EmptyArray),
            trusted: trusted,
            userField: AUTHOR
        );
        AddComments(lines: lines, comments: comments);

        lines.Add(JoinedLogins(JqOps.Field(value: issue, name: "assignees")));
        lines.Add(MilestoneTitle(issue));
        lines.Add(string.IsNullOrEmpty(planApproved) ? "false" : planApproved);

        return Finalise(lines: lines, schemaVersion: schemaVersion);
    }

    private static void AddPullRequestHeader(List<string> lines, JqValue pullRequest, JqValue trusted)
    {
        lines.Add(JqFormatter.Raw(JqOps.Field(value: pullRequest, name: "title")));
        lines.Add(
            JqFormatter.Raw(
                JqOps.Alternative(value: JqOps.Field(value: pullRequest, name: "body"), fallback: string.Empty)
            )
        );
        lines.Add(JqOps.ToText(JqOps.Field(value: pullRequest, name: "isDraft")));
        AddLabels(lines: lines, item: pullRequest);
        lines.Add(JqFormatter.Raw(JqOps.Field(value: pullRequest, name: "headRefOid")));
        lines.Add(
            JqFormatter.Raw(
                JqOps.Alternative(value: JqOps.Field(value: pullRequest, name: "baseRefName"), fallback: NONE)
            )
        );

        JqValue comments = TrustedOnly(
            items: ArrayOrEmpty(item: pullRequest, name: "comments"),
            trusted: trusted,
            userField: AUTHOR
        );
        JqValue humanComments = JqOps.Filter(
            value: comments,
            predicate: static comment => !AutomatedSummary.IsAutomatedSummary(JqOps.Field(value: comment, name: "body"))
        );
        AddComments(lines: lines, comments: humanComments);
    }

    private static void AddPullRequestReviews(List<string> lines, JqValue pullRequest, JqValue trusted)
    {
        JqValue reviews = TrustedOnly(
            items: ArrayOrEmpty(item: pullRequest, name: "reviews"),
            trusted: trusted,
            userField: AUTHOR
        );
        JqValue latest = JqOps.Last(
            JqOps.SortBy(
                value: reviews,
                key: static review => JqOps.Alternative(value: ReviewTimestamp(review), fallback: string.Empty)
            )
        );

        lines.Add(JqFormatter.Raw(JqOps.Alternative(value: JqOps.Field(value: latest, name: "state"), fallback: NONE)));
        lines.Add(JqFormatter.Raw(JqOps.Alternative(value: ReviewTimestamp(latest), fallback: NONE)));
        lines.Add(
            JqOps.Join(
                values: JqOps.Sort(
                    JqOps
                        .Iterate(reviews)
                        .Select(static review =>
                            JqValue.FromString(
                                JqOps.Tsv([
                                    JqOps.Alternative(value: ReviewTimestamp(review), fallback: NONE),
                                    JqOps.Alternative(
                                        value: JqOps.Field(value: review, name: "body"),
                                        fallback: string.Empty
                                    ),
                                ])
                            )
                        )
                ),
                separator: "\n"
            )
        );
        lines.Add(
            JqFormatter.Raw(
                JqOps.Alternative(value: JqOps.Field(value: pullRequest, name: "reviewDecision"), fallback: NONE)
            )
        );
    }

    private static void AddPullRequestPeople(List<string> lines, JqValue pullRequest)
    {
        IEnumerable<JqValue> reviewers = JqOps
            .Iterate(ArrayOrEmpty(item: pullRequest, name: "reviewRequests"))
            .Select(static request =>
                JqOps.Alternative(
                    value: JqOps.Alternative(
                        value: JqOps.Alternative(
                            value: JqOps.Field(value: request, name: "login"),
                            fallback: JqOps.Field(value: request, name: "slug")
                        ),
                        fallback: JqOps.Field(value: request, name: "name")
                    ),
                    fallback: "unknown"
                )
            );

        lines.Add(JqOps.Join(values: JqOps.Sort(reviewers), separator: ","));
        lines.Add(JoinedLogins(JqOps.Field(value: pullRequest, name: "assignees")));
        lines.Add(MilestoneTitle(pullRequest));
    }

    private static void AddPullRequestReviewComments(List<string> lines, JqValue reviewComments, JqValue trusted)
    {
        JqValue counted = TrustedOnly(items: reviewComments, trusted: trusted, userField: USER);
        JqValue latest = JqOps.Last(
            JqOps.SortBy(value: counted, key: static comment => JqOps.Field(value: comment, name: "updated_at"))
        );

        lines.Add(JqOps.ToText(JqOps.Length(counted)));
        lines.Add(
            JqFormatter.Raw(JqOps.Alternative(value: JqOps.Field(value: latest, name: "updated_at"), fallback: NONE))
        );
    }

    private static void AddPullRequestChecks(List<string> lines, JqValue pullRequest)
    {
        IEnumerable<JqValue> checks = JqOps
            .Iterate(ArrayOrEmpty(item: pullRequest, name: "statusCheckRollup"))
            .Select(static check => JqValue.FromString(CheckState(check)));

        lines.Add(JqOps.Join(values: JqOps.Sort(checks), separator: ","));
        lines.Add(
            JqFormatter.Raw(
                JqOps.Alternative(value: JqOps.Field(value: pullRequest, name: "mergeable"), fallback: UNKNOWN)
            )
        );
        lines.Add(
            JqFormatter.Raw(
                JqOps.Alternative(value: JqOps.Field(value: pullRequest, name: "mergeStateStatus"), fallback: UNKNOWN)
            )
        );
        lines.Add(JqOps.Field(value: pullRequest, name: "autoMergeRequest").Kind == JqKind.NULL ? "false" : "true");
    }

    private static string CheckState(JqValue check)
    {
        // (.conclusion // .status // .state // "none"): StatusContext checks only carry .state
        JqValue name = JqOps.Alternative(value: JqOps.Field(value: check, name: "name"), fallback: "unknown");
        JqValue state = JqOps.Alternative(
            value: JqOps.Alternative(
                value: JqOps.Alternative(
                    value: JqOps.Field(value: check, name: "conclusion"),
                    fallback: JqOps.Field(value: check, name: "status")
                ),
                fallback: JqOps.Field(value: check, name: "state")
            ),
            fallback: NONE
        );

        return JqOps.ToText(state) + ":" + JqOps.ToText(name);
    }

    private static JqValue ReviewTimestamp(JqValue review)
    {
        return JqOps.Alternative(
            value: JqOps.Field(value: review, name: "submittedAt"),
            fallback: JqOps.Field(value: review, name: "updatedAt")
        );
    }

    private static void AddLabels(List<string> lines, JqValue item)
    {
        IEnumerable<JqValue> names = JqOps
            .Iterate(ArrayOrEmpty(item: item, name: "labels"))
            .Select(static label => JqOps.Field(value: label, name: "name"));

        lines.AddRange(JqOps.Sort(names).Select(JqFormatter.Raw));
    }

    private static void AddComments(List<string> lines, JqValue comments)
    {
        IEnumerable<JqValue> rows = JqOps
            .Iterate(comments)
            .Select(static comment =>
                JqValue.FromString(
                    JqOps.Tsv([
                        JqOps.Alternative(value: JqOps.Field(value: comment, name: "updatedAt"), fallback: NONE),
                        JqOps.Alternative(value: JqOps.Field(value: comment, name: "body"), fallback: string.Empty),
                    ])
                )
            );

        lines.Add(JqOps.ToText(JqOps.Length(comments)));
        lines.Add(JqOps.Join(values: JqOps.Sort(rows), separator: "\n"));
    }

    private static string JoinedLogins(JqValue assignees)
    {
        IEnumerable<JqValue> logins = JqOps
            .Iterate(JqOps.Alternative(value: assignees, fallback: JqValue.EmptyArray))
            .Select(static assignee => JqOps.Field(value: assignee, name: "login"));

        return JqOps.Join(values: JqOps.Sort(logins), separator: ",");
    }

    private static string MilestoneTitle(JqValue item)
    {
        return JqFormatter.Raw(
            JqOps.Alternative(
                value: JqOps.Field(value: JqOps.Field(value: item, name: "milestone"), name: "title"),
                fallback: NONE
            )
        );
    }

    private static JqValue ArrayOrEmpty(JqValue item, string name)
    {
        return JqOps.Alternative(value: JqOps.Field(value: item, name: name), fallback: JqValue.EmptyArray);
    }

    // tc / trc: with no trusted list every item counts; otherwise only those whose .<user>.login is in it
    private static JqValue TrustedOnly(JqValue items, JqValue trusted, string userField)
    {
        if (trusted.Kind == JqKind.NULL)
        {
            return items;
        }

        return JqOps.Filter(
            value: items,
            predicate: item =>
                JqOps.Contains(
                    values: trusted,
                    item: JqOps.Field(value: JqOps.Field(value: item, name: userField), name: "login")
                )
        );
    }

    private static JqValue ParseOptional(string? json, string fallback)
    {
        return JqParser.Parse(string.IsNullOrEmpty(json) ? fallback : json);
    }

    // The shell refuses an empty canonical text because a jq failure upstream can leave one; here a
    // failure throws instead, and the last value (auto-merge, or the plan approval) is never empty.
    private static string Finalise(List<string> lines, int schemaVersion)
    {
        string canonical = string.Join(separator: '\n', values: lines)
            .Replace(oldValue: "\0", newValue: string.Empty, comparisonType: StringComparison.Ordinal)
            .TrimEnd('\n');
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(canonical));

        return schemaVersion.ToString(CultureInfo.InvariantCulture) + ":" + Convert.ToHexStringLower(hash);
    }
}
