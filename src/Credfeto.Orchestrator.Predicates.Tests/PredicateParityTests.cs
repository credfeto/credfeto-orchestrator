using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Predicates.Tests;

// Each case calls the .NET port as the shell function of the same name is called, with the shell's
// defaults for an argument left out or empty (${2:-null} and the like), and expects what the shell
// function printed and returned (0, or 1 for any failure)
public sealed class PredicateParityTests : TestBase
{
    private const string NULL_JSON = "null";
    private const string EMPTY_ARRAY_JSON = "[]";

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return PredicateParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task MatchesTheShellVersionAsync(int index, string name)
    {
        PredicateParityCase parity = await PredicateParityFixture.CaseAsync(
            index: index,
            cancellationToken: this.CancellationToken()
        );

        (int status, string output) = Run(parity);

        Assert.Equal(
            expected: Describe(name: name, status: parity.Status, output: parity.Output),
            actual: Describe(name: name, status: status, output: output)
        );
    }

    [Theory]
    [InlineData("LOOSE_PLAN_HEADING_PATTERN", PlanApprovalRule.LoosePlanHeadingPattern)]
    [InlineData("APPROVAL_LINE_KEYWORD_PATTERN", PlanApprovalRule.ApprovalLineKeywordPattern)]
    [InlineData("APPROVAL_NEGATION_PATTERN", PlanApprovalRule.ApprovalNegationPattern)]
    [InlineData("APPROVER_ASSOCIATIONS", PlanApprovalRule.ApproverAssociationsList)]
    public async Task PlanApprovalPatternsAreTheShellsAsync(string name, string expected)
    {
        string pattern = await PredicateParityFixture.PatternAsync(
            name: name,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: expected, actual: pattern);
    }

    private static (int Status, string Output) Run(PredicateParityCase parity)
    {
        IReadOnlyList<string> args = parity.Arguments;

        return parity.Function switch
        {
            "pr_json_has_placeholder_file" => Answer(PullRequestPredicates.HasPlaceholderFile(args[0])),
            "pr_json_has_only_passed_checks" => Answer(PullRequestPredicates.HasOnlyPassedChecks(args[0])),
            "pr_json_is_terminal" => Answer(
                PullRequestPredicates.IsTerminal(
                    pullRequestJson: args[0],
                    reviewPipelineFinishedJson: OrDefault(args: args, index: 1, fallback: "false")
                )
            ),
            "pr_json_has_failed_required_check" => Answer(PullRequestPredicates.HasFailedRequiredCheck(args[0])),
            "pr_json_has_failed_check_of_unknown_requiredness" => Answer(
                PullRequestPredicates.HasFailedCheckOfUnknownRequiredness(args[0])
            ),
            "pr_json_has_pending_ci_checks" => Answer(PullRequestPredicates.HasPendingCiChecks(args[0])),
            "pr_json_has_unaddressed_review_request" => Answer(
                PullRequestPredicates.HasUnaddressedReviewRequest(args[0])
            ),
            "pr_json_needs_review_approval" => Answer(PullRequestPredicates.NeedsReviewApproval(args[0])),
            "issue_json_has_plan_comment" => Answer(IssuePredicates.HasPlanComment(args[0])),
            "issue_json_has_human_plan_approval" => Answer(
                IssuePredicates.HasHumanPlanApproval(
                    issueJson: args[0],
                    meLogin: Raw(args: args, index: 1),
                    trustedLoginsJson: OrDefault(args: args, index: 2, fallback: NULL_JSON)
                )
            ),
            _ => RunRead(parity),
        };
    }

    private static (int Status, string Output) RunRead(PredicateParityCase parity)
    {
        IReadOnlyList<string> args = parity.Arguments;

        return parity.Function switch
        {
            "pr_json_latest_trusted_comment_timestamp" => Printed(
                PullRequestComments.LatestTrustedCommentTimestamp(
                    pullRequestJson: args[0],
                    trustedLoginsJson: OrDefault(args: args, index: 1, fallback: NULL_JSON),
                    reviewCommentsJson: OrDefault(args: args, index: 2, fallback: EMPTY_ARRAY_JSON),
                    issueCommentsJson: OrDefault(args: args, index: 3, fallback: EMPTY_ARRAY_JSON),
                    excludeLogin: Raw(args: args, index: 4)
                )
            ),
            "pr_json_has_unaddressed_trusted_comment" => Status(
                PullRequestComments.HasUnaddressedTrustedComment(
                    pullRequestJson: args[0],
                    trustedLoginsJson: OrDefault(args: args, index: 1, fallback: NULL_JSON),
                    lastSeenTimestamp: Raw(args: args, index: 2),
                    reviewCommentsJson: OrDefault(args: args, index: 3, fallback: EMPTY_ARRAY_JSON),
                    issueCommentsJson: OrDefault(args: args, index: 4, fallback: EMPTY_ARRAY_JSON),
                    excludeLogin: Raw(args: args, index: 5)
                )
            ),
            "pr_json_unaddressed_trusted_comments_text" => Printed(
                PullRequestComments.UnaddressedTrustedCommentsText(
                    pullRequestJson: args[0],
                    trustedLoginsJson: OrDefault(args: args, index: 1, fallback: NULL_JSON),
                    lastSeenTimestamp: Raw(args: args, index: 2),
                    reviewCommentsJson: OrDefault(args: args, index: 3, fallback: EMPTY_ARRAY_JSON),
                    issueCommentsJson: OrDefault(args: args, index: 4, fallback: EMPTY_ARRAY_JSON),
                    excludeLogin: Raw(args: args, index: 5),
                    perCommentMaximum: parity.PerCommentMaximum
                )
            ),
            "annotate_pr_json_required_checks" => (
                0,
                PullRequestJson.AnnotateRequiredChecks(
                    pullRequestJson: args[0],
                    requiredNamesJson: Raw(args: args, index: 1),
                    baseRequiresChecks: Raw(args: args, index: 2)
                )
            ),
            "pr_json_env_block_image_sha" => Printed(PullRequestJson.EnvBlockImageSha(args[0])),
            "pr_json_lowest_closing_issue" => Printed(
                PullRequestJson.LowestClosingIssue(pullRequestJson: args[0], repository: Raw(args: args, index: 1))
            ),
            _ => throw new InvalidOperationException("No .NET port for " + parity.Function),
        };
    }

    // ${n:-fallback}
    private static string OrDefault(IReadOnlyList<string> args, int index, string fallback)
    {
        string value = Raw(args: args, index: index);

        return value.Length == 0 ? fallback : value;
    }

    private static string Raw(IReadOnlyList<string> args, int index)
    {
        return index < args.Count ? args[index] : string.Empty;
    }

    private static (int Status, string Output) Answer(PredicateAnswer answer)
    {
        return Status(answer.Holds);
    }

    private static (int Status, string Output) Status(bool holds)
    {
        return (holds ? 0 : 1, string.Empty);
    }

    private static (int Status, string Output) Printed(PredicateOutput output)
    {
        return output.Succeeded ? (0, output.Printed) : (1, string.Empty);
    }

    private static string Describe(string name, int status, string output)
    {
        return name + ": status " + status.ToString(CultureInfo.InvariantCulture) + ", output " + Escape(output);
    }

    private static string Escape(string text)
    {
        return text.Replace(oldValue: "\n", newValue: "\\n", comparisonType: StringComparison.Ordinal)
            .Replace(oldValue: "\r", newValue: "\\r", comparisonType: StringComparison.Ordinal);
    }
}
