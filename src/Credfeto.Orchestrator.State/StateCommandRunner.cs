using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.State;

// credfeto-orchestrator state ...: answers a read-only lib/state query from the same state file, printing what the
// shell function prints (or leaves in its global), byte for byte, and exiting with the status it returns; or writes a
// state file as its lib/state function writes it, printing nothing
public sealed class StateCommandRunner
{
    public const int Usage = 2;

    // The query cannot be answered exactly as bash would answer it, so lib/state answers it in bash
    public const int Refused = 3;

    // The answer, or the state file, could not be written
    public const int Failed = 125;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator state infra-failures|invocations|last-diagnostic --session-dir <dir>
                   --type <type> --id <id>
               credfeto-orchestrator state env-unblock-attempts --session-dir <dir> --id <id>
               credfeto-orchestrator state marker --session-dir <dir> --type <type> --id <id> --kind <kind>
               credfeto-orchestrator state precheck-result --session-dir <dir> --key <key> --sha <sha>
               credfeto-orchestrator state pull-duration-baseline --state-dir <dir> --owner <owner> --min-samples <n>
               credfeto-orchestrator state rate-limit --state-dir <dir> --owner <owner>
               credfeto-orchestrator state session-denials-summary --file <file>
               credfeto-orchestrator state save-infra-failures --session-dir <dir> --type <type> --id <id>
                   --count <n>
               credfeto-orchestrator state save-invocations --session-dir <dir> --type <type> --id <id> --total <n>
                   --idle <n>
               credfeto-orchestrator state save-env-unblock-attempts --session-dir <dir> --id <id> --total <n>
               credfeto-orchestrator state save-rate-limit --state-dir <dir> --owner <owner> --reset <unix time>
               credfeto-orchestrator state save-precheck-result --session-dir <dir> --key <key> --sha <sha>
                   --status <status>
               credfeto-orchestrator state save-last-diagnostic --session-dir <dir> --type <type> --id <id> < text

        Each query reads the state file its lib/state function reads (--session-dir is SESSION_BASE_DIR, --state-dir
        ORCHESTRATOR_STATE_DIR) and prints what the function prints, or leaves in its global: infra-failures
        load_infra_failure_count, invocations (--type PullRequest or Issue) load_pr_invocation_counts or
        load_issue_invocation_counts as "<total> <idle>", env-unblock-attempts load_env_unblock_attempts, marker
        (--kind plan-block, blocked-replan or background-stall) issue_plan_block_marked, issue_blocked_replan_marked or
        background_stall_marked, last-diagnostic load_last_diagnostic, precheck-result load_precheck_result,
        pull-duration-baseline pull_duration_baseline, rate-limit is_owner_rate_limited and session-denials-summary
        summarise_session_denials_day.

        Each save- command writes the file its lib/state function writes, with the same bytes, and leaves it with the
        mode, owner and group that function's write leaves: save-infra-failures save_infra_failure_count,
        save-invocations save_pr_invocation_counts or save_issue_invocation_counts, save-env-unblock-attempts
        save_env_unblock_attempts, save-rate-limit save_rate_limit, save-precheck-result save_precheck_result and
        save-last-diagnostic save_last_diagnostic, whose text is stdin up to the newline a here-string ends it with.
        The file is replaced by renaming a complete copy over it, so it is never seen half written.

        Exit codes: 0 or 1 the answer, 0 written; 4 (rate-limit) not rate-limited and the file is stale, so the caller
        removes it; 2 a usage error; 3 the query cannot be answered exactly as bash would (an argument that is not
        UTF-8, a file that cannot be read or holds a NUL byte, or text bash reads by the locale's rules), so lib/state
        answers it, or a write a rename would leave differently from bash's (no directory yet, a link, a directory, a
        file with more than one link or that cannot be written, another owner or group, or a part of the file name
        holding a slash), so lib/state writes it; 125 the answer or the file could not be written, and a file is as it
        was.
        """;

    private readonly Func<Stream> _input;
    private readonly StateQueries _queries;

    public StateCommandRunner(StateQueries queries)
        : this(queries: queries, input: () => Stream.Null) { }

    // input opens what save-last-diagnostic reads its text from
    public StateCommandRunner(StateQueries queries, Func<Stream> input)
    {
        this._queries = queries;
        this._input = input;
    }

    public static StateCommandRunner CreateDefault()
    {
        return new(queries: new StateQueries(TimeProvider.System), input: Console.OpenStandardInput);
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Stream output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        StateCommand? command = StateCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
            await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return Usage;
        }

        try
        {
            RefuseReplacedArguments(command);

            if (StateWrites.Handles(command.Query))
            {
                return await this.WriteAsync(command: command, cancellationToken: cancellationToken);
            }

            StateResult answer = await this.AnswerAsync(command: command, cancellationToken: cancellationToken);
            await output.WriteAsync(answer.Output, cancellationToken);
            await output.FlushAsync(cancellationToken);

            return answer.ExitCode;
        }
        catch (StateRefusedException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Refused, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return Cancelled;
        }
        catch (IOException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Failed, cancellationToken);
        }
    }

    private async ValueTask<int> WriteAsync(StateCommand command, CancellationToken cancellationToken)
    {
        await using Stream input = this._input();
        await StateWrites.WriteAsync(command: command, input: input, cancellationToken: cancellationToken);

        return StateQueries.Answered;
    }

    // An argument that was not UTF-8 reaches .NET with U+FFFD in place of the bad bytes, so it no longer names the
    // file bash would read
    private static void RefuseReplacedArguments(StateCommand command)
    {
        if (command.Options.Values.Any(value => value.Contains('\uFFFD', StringComparison.Ordinal)))
        {
            throw new StateRefusedException("an argument is not UTF-8");
        }
    }

    private ValueTask<StateResult> AnswerAsync(StateCommand command, CancellationToken cancellationToken)
    {
        return command.Query switch
        {
            StateQuery.INFRA_FAILURES or StateQuery.INVOCATIONS or StateQuery.LAST_DIAGNOSTIC => AnswerItemAsync(
                command: command,
                cancellationToken: cancellationToken
            ),
            StateQuery.ENV_UNBLOCK_ATTEMPTS => StateQueries.EnvUnblockAttemptsAsync(
                sessionDirectory: command.Option(StateCommandParser.SessionDirectory),
                itemId: command.Option(StateCommandParser.ItemId),
                cancellationToken: cancellationToken
            ),
            StateQuery.MARKER => ValueTask.FromResult(
                StateQueries.Marker(
                    sessionDirectory: command.Option(StateCommandParser.SessionDirectory),
                    itemType: command.Option(StateCommandParser.ItemType),
                    itemId: command.Option(StateCommandParser.ItemId),
                    kind: command.Option(StateCommandParser.Kind)
                )
            ),
            StateQuery.PRECHECK_RESULT => StateQueries.PrecheckResultAsync(
                sessionDirectory: command.Option(StateCommandParser.SessionDirectory),
                key: command.Option(StateCommandParser.Key),
                sha: command.Option(StateCommandParser.Sha),
                cancellationToken: cancellationToken
            ),
            StateQuery.PULL_DURATION_BASELINE => StateQueries.PullDurationBaselineAsync(
                stateDirectory: command.Option(StateCommandParser.StateDirectory),
                owner: command.Option(StateCommandParser.Owner),
                minSamples: command.Option(StateCommandParser.MinSamples),
                cancellationToken: cancellationToken
            ),
            StateQuery.RATE_LIMIT => this._queries.RateLimitAsync(
                stateDirectory: command.Option(StateCommandParser.StateDirectory),
                owner: command.Option(StateCommandParser.Owner),
                cancellationToken: cancellationToken
            ),
            _ => StateQueries.SessionDenialsSummaryAsync(
                file: command.Option(StateCommandParser.File),
                cancellationToken: cancellationToken
            ),
        };
    }

    // The queries over one item's file: <SESSION_BASE_DIR>/<type>_<id>.<suffix>
    private static ValueTask<StateResult> AnswerItemAsync(StateCommand command, CancellationToken cancellationToken)
    {
        string session = command.Option(StateCommandParser.SessionDirectory);
        string type = command.Option(StateCommandParser.ItemType);
        string id = command.Option(StateCommandParser.ItemId);

        if (command.Query == StateQuery.INFRA_FAILURES)
        {
            return StateQueries.InfraFailuresAsync(
                sessionDirectory: session,
                itemType: type,
                itemId: id,
                cancellationToken: cancellationToken
            );
        }

        return command.Query == StateQuery.INVOCATIONS
            ? StateQueries.InvocationsAsync(
                sessionDirectory: session,
                itemType: type,
                itemId: id,
                cancellationToken: cancellationToken
            )
            : StateQueries.LastDiagnosticAsync(
                sessionDirectory: session,
                itemType: type,
                itemId: id,
                cancellationToken: cancellationToken
            );
    }

    private static async ValueTask<int> FailAsync(
        TextWriter error,
        string message,
        int status,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: state: {message}".AsMemory(), cancellationToken);

        return status;
    }
}
