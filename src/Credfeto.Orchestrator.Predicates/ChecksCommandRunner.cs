using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Predicates;

// credfeto-orchestrator checks ...: answers a lib/github-status routing read or a lib/workflow-board label read as
// the shell function does, printing what it prints and exiting 0 where it returns 0
public static class ChecksCommandRunner
{
    // The function returns non-zero (for next-phase, 2: the board status names no phase)
    public const int No = 1;

    public const int Usage = 2;

    // The query cannot be answered exactly as bash would answer it, so bash answers it
    public const int Refused = 3;

    // stdin could not be read or the answer could not be written
    public const int Failed = 125;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator checks next-phase --board-status <status> --required-checks-unknown <true|false>
               credfeto-orchestrator checks merge-state-allows-settled --merge-state <state>
               credfeto-orchestrator checks session-progress-reason --pre-board <status> --post-board <status>
                   --pre-comment-ts <time> --post-comment-ts <time> --pre-head <sha> --post-head <sha>
               credfeto-orchestrator checks clean-review-comment --status <status>
               credfeto-orchestrator checks has-blocked-label
               credfeto-orchestrator checks priority-for-labels

        Each query answers as its shell function does with the same arguments, printing what it prints:
        next-phase pr_next_phase_for_board_status, merge-state-allows-settled pr_merge_state_allows_settled
        (both read the pull request JSON on stdin), session-progress-reason pr_session_progress_reason,
        clean-review-comment pr_clean_review_status_comment, has-blocked-label pr_json_has_blocked_label and
        issue_json_has_blocked_label (the pull request or Issue JSON on stdin), all in lib/github-status, and
        priority-for-labels priority_for_labels (lib/workflow-board; the labels JSON on stdin). The other queries
        never read stdin.

        Exit codes: 0 the function returns 0; 1 it does not (next-phase: the board status names no phase, where the
        function returns 2); 2 a usage error; 3 the query cannot be answered exactly as bash would (an argument that
        is not UTF-8, JSON starting with a byte order mark, comment times the locale could order differently, or a
        label name grep could read differently), so bash answers it; 125 stdin could not be read or the answer could
        not be written.
        """;

    private static ReadOnlySpan<byte> ByteOrderMark => [0xEF, 0xBB, 0xBF];

    private static readonly Encoding Utf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    public static async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Func<Stream> input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        try
        {
            ChecksCommand? command = ChecksCommandParser.Parse(args: args, error: out string problem);

            if (command is null)
            {
                await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
                await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

                return Usage;
            }

            ChecksAnswer answer = await AnswerAsync(
                command: command,
                input: input,
                cancellationToken: cancellationToken
            );

            if (answer.Refusal is not null)
            {
                await error.WriteLineAsync($"{PROGRAM}: checks: {answer.Refusal}".AsMemory(), cancellationToken);

                return Refused;
            }

            await output.WriteAsync(answer.Printed.AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            return answer.Holds ? 0 : No;
        }
        catch (IOException exception)
        {
            await error.WriteLineAsync($"{PROGRAM}: checks: {exception.Message}".AsMemory(), cancellationToken);

            return Failed;
        }
        catch (OperationCanceledException)
        {
            return Cancelled;
        }
    }

    private static async ValueTask<ChecksAnswer> AnswerAsync(
        ChecksCommand command,
        Func<Stream> input,
        CancellationToken cancellationToken
    )
    {
        // .NET decodes an argument that is not UTF-8 with replacement characters, so it is not the text bash has
        if (
            command.Options.Values.Any(static value =>
                value.Contains(value: '�', comparisonType: StringComparison.Ordinal)
            )
        )
        {
            return ChecksAnswer.Refused("an argument is not UTF-8");
        }

        if (!ChecksCommandParser.ReadsInput(command.Query))
        {
            return Answer(command: command, json: string.Empty);
        }

        byte[] bytes = await ReadInputAsync(input: input, cancellationToken: cancellationToken);

        // jq skips a byte order mark at the start of its input; the parser here would not
        if (bytes.AsSpan().StartsWith(ByteOrderMark))
        {
            return ChecksAnswer.Refused("the JSON starts with a byte order mark");
        }

        return Answer(command: command, json: Utf8.GetString(bytes));
    }

    private static ChecksAnswer Answer(ChecksCommand command, string json)
    {
        return command.Query switch
        {
            ChecksQuery.NEXT_PHASE => PullRequestRouting.NextPhase(
                boardStatus: command.Option(ChecksCommandParser.BOARD_STATUS),
                pullRequestJson: json,
                requiredChecksUnknown: command.Option(ChecksCommandParser.REQUIRED_CHECKS_UNKNOWN)
            ),
            ChecksQuery.MERGE_STATE_ALLOWS_SETTLED => PullRequestRouting.MergeStateAllowsSettled(
                pullRequestJson: json,
                mergeState: command.Option(ChecksCommandParser.MERGE_STATE)
            ),
            ChecksQuery.SESSION_PROGRESS_REASON => SessionProgress.Reason(
                preBoard: command.Option(ChecksCommandParser.PRE_BOARD),
                postBoard: command.Option(ChecksCommandParser.POST_BOARD),
                preCommentTimestamp: command.Option(ChecksCommandParser.PRE_COMMENT_TS),
                postCommentTimestamp: command.Option(ChecksCommandParser.POST_COMMENT_TS),
                preHead: command.Option(ChecksCommandParser.PRE_HEAD),
                postHead: command.Option(ChecksCommandParser.POST_HEAD)
            ),
            ChecksQuery.CLEAN_REVIEW_COMMENT => PullRequestRouting.CleanReviewStatusComment(
                command.Option(ChecksCommandParser.STATUS)
            ),
            ChecksQuery.HAS_BLOCKED_LABEL => LabelReads.HasBlockedLabel(json),
            _ => ChecksAnswer.Printing(LabelReads.PriorityForLabels(json)),
        };
    }

    private static async ValueTask<byte[]> ReadInputAsync(Func<Stream> input, CancellationToken cancellationToken)
    {
        await using Stream stream = input();
        using MemoryStream buffer = new();
        await stream.CopyToAsync(destination: buffer, cancellationToken: cancellationToken);

        return buffer.ToArray();
    }
}
