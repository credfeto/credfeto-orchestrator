using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Predicates;

namespace Credfeto.Orchestrator.Commands;

// Runs a predicate command over the JSON read from stdin. A predicate prints true (exit 0) or false
// (exit 3); the other commands print what their shell function prints and exit 0, or exit 3 when
// that function finds nothing. Exit 1 is input jq itself would fail on, which the shell reads as false
// or as the function failing, as it reads a jq failure.
public sealed class PredicateCommandRunner
{
    private const string NULL_JSON = "null";
    private const string EMPTY_ARRAY_JSON = "[]";

    private readonly IFileContentReader _files;

    public PredicateCommandRunner(IFileContentReader files)
    {
        this._files = files;
    }

    public async ValueTask<PredicateOutcome> RunAsync(
        PredicateCommand command,
        string input,
        CancellationToken cancellationToken
    )
    {
        return command.Kind switch
        {
            PredicateKind.PR_HAS_PLACEHOLDER_FILE => Answer(PullRequestPredicates.HasPlaceholderFile(input)),
            PredicateKind.PR_HAS_ONLY_PASSED_CHECKS => Answer(PullRequestPredicates.HasOnlyPassedChecks(input)),
            PredicateKind.PR_IS_TERMINAL => Answer(
                PullRequestPredicates.IsTerminal(
                    pullRequestJson: input,
                    reviewPipelineFinishedJson: Option(
                        command: command,
                        name: PredicateCommandParser.ReviewPipelineFinished,
                        fallback: "false"
                    )
                )
            ),
            PredicateKind.PR_HAS_FAILED_REQUIRED_CHECK => Answer(PullRequestPredicates.HasFailedRequiredCheck(input)),
            PredicateKind.PR_HAS_FAILED_CHECK_OF_UNKNOWN_REQUIREDNESS => Answer(
                PullRequestPredicates.HasFailedCheckOfUnknownRequiredness(input)
            ),
            PredicateKind.PR_HAS_PENDING_CI_CHECKS => Answer(PullRequestPredicates.HasPendingCiChecks(input)),
            PredicateKind.PR_HAS_UNADDRESSED_REVIEW_REQUEST => Answer(
                PullRequestPredicates.HasUnaddressedReviewRequest(input)
            ),
            PredicateKind.PR_NEEDS_REVIEW_APPROVAL => Answer(PullRequestPredicates.NeedsReviewApproval(input)),
            PredicateKind.ISSUE_HAS_PLAN_COMMENT => Answer(IssuePredicates.HasPlanComment(input)),
            _ => await this.RunWithFilesAsync(command: command, input: input, cancellationToken: cancellationToken),
        };
    }

    private async ValueTask<PredicateOutcome> RunWithFilesAsync(
        PredicateCommand command,
        string input,
        CancellationToken cancellationToken
    )
    {
        return command.Kind switch
        {
            PredicateKind.ISSUE_HAS_HUMAN_PLAN_APPROVAL => Answer(
                IssuePredicates.HasHumanPlanApproval(
                    issueJson: input,
                    meLogin: Option(command: command, name: PredicateCommandParser.Me, fallback: string.Empty),
                    trustedLoginsJson: await this.FileAsync(
                        command: command,
                        name: PredicateCommandParser.TrustedFile,
                        fallback: NULL_JSON,
                        cancellationToken: cancellationToken
                    )
                )
            ),
            PredicateKind.PR_LATEST_TRUSTED_COMMENT_TIMESTAMP => Output(
                await this.LatestTrustedCommentTimestampAsync(
                    command: command,
                    input: input,
                    cancellationToken: cancellationToken
                )
            ),
            PredicateKind.PR_UNADDRESSED_TRUSTED_COMMENTS => Output(
                await this.UnaddressedTrustedCommentsAsync(
                    command: command,
                    input: input,
                    cancellationToken: cancellationToken
                )
            ),
            PredicateKind.PR_ANNOTATE_REQUIRED_CHECKS => new(
                Printed: PullRequestJson.AnnotateRequiredChecks(
                    pullRequestJson: input,
                    requiredNamesJson: await this.FileAsync(
                        command: command,
                        name: PredicateCommandParser.RequiredFile,
                        fallback: string.Empty,
                        cancellationToken: cancellationToken
                    ),
                    baseRequiresChecks: Option(
                        command: command,
                        name: PredicateCommandParser.BaseRequiresChecks,
                        fallback: string.Empty
                    )
                ),
                ExitCode: ExitCodes.Success,
                Problem: null
            ),
            PredicateKind.PR_ENV_BLOCK_IMAGE_SHA => Output(PullRequestJson.EnvBlockImageSha(input)),
            _ => Output(
                PullRequestJson.LowestClosingIssue(
                    pullRequestJson: input,
                    repository: Option(
                        command: command,
                        name: PredicateCommandParser.Repository,
                        fallback: string.Empty
                    )
                )
            ),
        };
    }

    private async ValueTask<PredicateOutput> LatestTrustedCommentTimestampAsync(
        PredicateCommand command,
        string input,
        CancellationToken cancellationToken
    )
    {
        CommentInputs inputs = await this.CommentInputsAsync(command: command, cancellationToken: cancellationToken);

        return PullRequestComments.LatestTrustedCommentTimestamp(
            pullRequestJson: input,
            trustedLoginsJson: inputs.Trusted,
            reviewCommentsJson: inputs.ReviewComments,
            issueCommentsJson: inputs.IssueComments,
            excludeLogin: Option(command: command, name: PredicateCommandParser.ExcludeLogin, fallback: string.Empty)
        );
    }

    private async ValueTask<PredicateOutput> UnaddressedTrustedCommentsAsync(
        PredicateCommand command,
        string input,
        CancellationToken cancellationToken
    )
    {
        CommentInputs inputs = await this.CommentInputsAsync(command: command, cancellationToken: cancellationToken);

        return PullRequestComments.UnaddressedTrustedCommentsText(
            pullRequestJson: input,
            trustedLoginsJson: inputs.Trusted,
            lastSeenTimestamp: Option(command: command, name: PredicateCommandParser.LastSeen, fallback: string.Empty),
            reviewCommentsJson: inputs.ReviewComments,
            issueCommentsJson: inputs.IssueComments,
            excludeLogin: Option(command: command, name: PredicateCommandParser.ExcludeLogin, fallback: string.Empty),
            perCommentMaximum: int.Parse(
                s: command.Options[PredicateCommandParser.PerCommentMaximum],
                provider: CultureInfo.InvariantCulture
            )
        );
    }

    private async ValueTask<CommentInputs> CommentInputsAsync(
        PredicateCommand command,
        CancellationToken cancellationToken
    )
    {
        return new(
            Trusted: await this.FileAsync(
                command: command,
                name: PredicateCommandParser.TrustedFile,
                fallback: NULL_JSON,
                cancellationToken: cancellationToken
            ),
            ReviewComments: await this.FileAsync(
                command: command,
                name: PredicateCommandParser.ReviewCommentsFile,
                fallback: EMPTY_ARRAY_JSON,
                cancellationToken: cancellationToken
            ),
            IssueComments: await this.FileAsync(
                command: command,
                name: PredicateCommandParser.IssueCommentsFile,
                fallback: EMPTY_ARRAY_JSON,
                cancellationToken: cancellationToken
            )
        );
    }

    private async ValueTask<string> FileAsync(
        PredicateCommand command,
        string name,
        string fallback,
        CancellationToken cancellationToken
    )
    {
        return command.Options.TryGetValue(key: name, value: out string? path)
            ? await this._files.ReadAllTextAsync(path: path, cancellationToken: cancellationToken)
            : fallback;
    }

    private static string Option(PredicateCommand command, string name, string fallback)
    {
        return command.Options.GetValueOrDefault(key: name, defaultValue: fallback);
    }

    private static PredicateOutcome Answer(PredicateAnswer answer)
    {
        if (answer.Holds)
        {
            return new(Printed: "true\n", ExitCode: ExitCodes.Success, Problem: null);
        }

        return answer.Problem is null
            ? new(Printed: "false\n", ExitCode: ExitCodes.No, Problem: null)
            : new(Printed: string.Empty, ExitCode: ExitCodes.Failure, Problem: answer.Problem);
    }

    private static PredicateOutcome Output(PredicateOutput output)
    {
        if (output.Succeeded)
        {
            return new(Printed: output.Printed, ExitCode: ExitCodes.Success, Problem: null);
        }

        return output.Problem is null
            ? new(Printed: string.Empty, ExitCode: ExitCodes.No, Problem: null)
            : new(Printed: string.Empty, ExitCode: ExitCodes.Failure, Problem: output.Problem);
    }
}
